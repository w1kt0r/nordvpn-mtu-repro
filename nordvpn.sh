#!/bin/sh
# The same topology as repro.sh, but each peer runs the official NordVPN Linux
# client with Meshnet, which sets the nordlynx MTU itself (default-route MTU - 80).
#
#   NORDVPN_TOKEN=<access token> ./nordvpn.sh all
#
# Both peers sign in with the same token, so they are two devices of one account
# and see each other in Meshnet. The router drops packets longer than PATH_MAX
# only between the two peer networks; internet traffic (NordVPN's API, relays)
# is not affected. If Meshnet picks a relayed connection instead of the direct
# one, the drop rule is bypassed and the stall does not show; the script prints
# which path is used.
set -eu
cd "$(dirname "$0")"
: "${NORDVPN_TOKEN:?set NORDVPN_TOKEN to a NordVPN access token}"
IMG=localhost/nordvpn-mtu-repro-client:latest
PATH_MAX=${PATH_MAX:-1478}
P=podman

up() {
    $P build -q -t "$IMG" -f Containerfile.nordvpn . >/dev/null
    $P build -q -t localhost/nordvpn-mtu-repro:latest -f Containerfile . >/dev/null
    $P network exists mtu_a || $P network create --subnet 10.91.1.0/24 mtu_a >/dev/null
    $P network exists mtu_b || $P network create --subnet 10.91.2.0/24 mtu_b >/dev/null
    $P run -d --name mtu-router --network mtu_a:ip=10.91.1.2 --network mtu_b:ip=10.91.2.2 \
        --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 localhost/nordvpn-mtu-repro:latest >/dev/null
    $P exec mtu-router sh -c 'iptables -t nat -A POSTROUTING -o eth0 -s 10.91.2.0/24 -d 10.91.1.0/24 -j MASQUERADE
        iptables -t nat -A POSTROUTING -o eth1 -s 10.91.1.0/24 -d 10.91.2.0/24 -j MASQUERADE'
    $P exec mtu-router iptables -A FORWARD -s 10.91.0.0/16 -d 10.91.0.0/16 -m length --length "$((PATH_MAX + 1)):65535" -j DROP
    for p in a b; do
        n=$([ $p = a ] && echo 1 || echo 2)
        $P run -d --name mtu-peer-$p --hostname mtu-peer-$p --network mtu_$p:ip=10.91.$n.10 \
            --cap-add NET_ADMIN --cap-add NET_RAW --device /dev/net/tun \
            -e NORDVPN_TOKEN -e NICKNAME=mtu-peer-$p "$IMG" >/dev/null
    done
    $P exec mtu-peer-a ip route add 10.91.2.0/24 via 10.91.1.2
    $P exec mtu-peer-b ip route add 10.91.1.0/24 via 10.91.2.2
    echo "waiting for both peers to join Meshnet..."
    for i in $(seq 1 60); do
        B_IP=$($P exec mtu-peer-b sh -c "ip -4 -o addr show nordlynx 2>/dev/null | awk '{print \$4}' | cut -d/ -f1")
        [ -n "$B_IP" ] && $P exec mtu-peer-a nordvpn meshnet peer list 2>/dev/null | grep -q "$B_IP" && break
        sleep 2
    done
    [ -n "${B_IP:-}" ] || { echo "Meshnet did not come up; see: podman exec mtu-peer-b cat /var/log/nordvpnd.log" >&2; exit 1; }
    $P exec mtu-peer-b sh -c "mkdir -p /srv && head -c 1048576 /dev/urandom > /srv/file.bin && (cd /srv && nohup python3 -m http.server 8000 --bind $B_IP >/dev/null 2>&1 &)"
    sleep 2
    echo "up: peer-b Meshnet address $B_IP; path drops packets > $PATH_MAX bytes between the peers"
}

case "${1:-all}" in
    up) up ;;
    test|all)
        [ "${1:-all}" = all ] && { ./repro.sh down >/dev/null; up; }
        B_IP=$($P exec mtu-peer-b sh -c "ip -4 -o addr show nordlynx | awk '{print \$4}' | cut -d/ -f1")
        echo "== NordVPN client, MTU as the client sets it"
        PEER_A=mtu-peer-a PEER_B_IP=$B_IP TUN_IF=nordlynx ./repro.sh test
        echo "--- router counter of dropped oversized packets:"
        $P exec mtu-router iptables -L FORWARD -v -n | awk '/DROP/{print "    " $1 " packets"}'
        [ "${1:-all}" = all ] && ./repro.sh down >/dev/null; true ;;
    down) ./repro.sh down ;;
    *) echo "usage: $0 up|test|down|all" >&2; exit 2 ;;
esac
