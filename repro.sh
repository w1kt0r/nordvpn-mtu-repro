#!/bin/sh
# Reproduce: WireGuard tunnel MTU 1420 (= 1500 - 80, as nordvpn-linux computes it)
# over a path that silently drops packets larger than 1478 bytes.
#
#   peer-a (10.91.1.10) --- net_a --- router --- net_b --- peer-b (10.91.2.10)
#   wg0 100.64.0.1/24  ============ WireGuard ============  wg0 100.64.0.2/24
#
# The router forwards between the two networks and drops (without any ICMP
# reply) every packet longer than PATH_MAX bytes: the behaviour measured on a
# real Meshnet path. peer-b serves a 1 MB file; peer-a downloads it through
# the tunnel.
#
# Kernel WireGuard pads packets to a multiple of 16 bytes, so here the largest
# packet that passes is 1408 rather than 1418; the stall is the same.
#
# Usage: ./repro.sh up | test | fix-mtu | reset | down | all
#        PROBING=1 ./repro.sh up    peers start with net.ipv4.tcp_mtu_probing=1
set -eu
cd "$(dirname "$0")"
IMG=localhost/nordvpn-mtu-repro:latest
PATH_MAX=${PATH_MAX:-1478}   # largest outer packet the path carries
WG_MTU=${WG_MTU:-1420}       # what the client sets: default-route MTU (1500) - 80
P="podman"

up() {
    $P build -q -t "$IMG" -f Containerfile . >/dev/null
    $P network exists mtu_a || $P network create --subnet 10.91.1.0/24 mtu_a >/dev/null
    $P network exists mtu_b || $P network create --subnet 10.91.2.0/24 mtu_b >/dev/null
    $P run -d --name mtu-router --network mtu_a:ip=10.91.1.2 --network mtu_b:ip=10.91.2.2 \
        --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 "$IMG" >/dev/null
    for p in a b; do
        n=$([ $p = a ] && echo 1 || echo 2)
        $P run -d --name mtu-peer-$p --network mtu_$p:ip=10.91.$n.10 --cap-add NET_ADMIN \
            --sysctl net.ipv4.tcp_mtu_probing="${PROBING:-0}" "$IMG" >/dev/null
    done
    # the router: forward with address translation (like a home router; it also keeps
    # podman's own bridge firewall out of the way), and silently drop anything
    # longer than PATH_MAX
    $P exec mtu-router sh -c 'iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE'
    $P exec mtu-router iptables -A FORWARD -m length --length "$((PATH_MAX + 1)):65535" -j DROP
    # peers reach each other only through the router
    $P exec mtu-peer-a ip route add 10.91.2.0/24 via 10.91.1.2
    $P exec mtu-peer-b ip route add 10.91.1.0/24 via 10.91.2.2
    # WireGuard between the peers
    ka=$($P exec mtu-peer-a wg genkey); kb=$($P exec mtu-peer-b wg genkey)
    pa=$(echo "$ka" | $P exec -i mtu-peer-a wg pubkey); pb=$(echo "$kb" | $P exec -i mtu-peer-b wg pubkey)
    wgset mtu-peer-a "$ka" 100.64.0.1 "$pb" 10.91.2.10 100.64.0.2
    wgset mtu-peer-b "$kb" 100.64.0.2 "$pa" 10.91.1.10 100.64.0.1
    $P exec mtu-peer-b sh -c 'mkdir -p /srv && head -c 1048576 /dev/urandom > /srv/file.bin && (cd /srv && nohup python3 -m http.server 8000 --bind 100.64.0.2 >/dev/null 2>&1 &)'
    sleep 1
    echo "up: tunnel MTU $WG_MTU, path drops packets > $PATH_MAX bytes, tcp_mtu_probing=${PROBING:-0}"
}

wgset() { # container privkey my_ip peer_pub peer_endpoint peer_ip
    # keys under /etc/wireguard: some hosts (Ubuntu) confine the wg tool to that path with AppArmor
    $P exec -i "$1" sh -c "umask 077; mkdir -p /etc/wireguard; cat > /etc/wireguard/wg0.key; ip link add wg0 type wireguard; wg set wg0 private-key /etc/wireguard/wg0.key listen-port 51820 peer $4 endpoint $5:51820 allowed-ips $6/32 persistent-keepalive 5; ip addr add $3/24 dev wg0; ip link set wg0 mtu $WG_MTU up" <<K
$2
K
}

test_() {
    A=${PEER_A:-mtu-peer-a}; B_IP=${PEER_B_IP:-100.64.0.2}
    lo=1200; hi=$WG_MTU
    while [ $((hi - lo)) -gt 1 ]; do
        m=$(((lo + hi) / 2))
        if $P exec "$A" ping -c 1 -W 2 -M do -s $((m - 28)) "$B_IP" >/dev/null 2>&1; then lo=$m; else hi=$m; fi
    done
    echo "--- largest packet through the tunnel (Don't Fragment ping): $lo bytes; tunnel MTU: $($P exec "$A" cat /sys/class/net/${TUN_IF:-wg0}/mtu)"
    echo "--- download 1 MB through the tunnel (15 s limit):"
    $P exec "$A" curl -s -o /dev/null -m 15 -w '    HTTP %{http_code}, %{size_download} of 1048576 bytes in %{time_total} s\n' "http://$B_IP:8000/file.bin" || true
}

fix_mtu() { for p in a b; do $P exec mtu-peer-$p ip link set wg0 mtu 1400; done; echo "fix: wg0 MTU 1400 on both peers"; }
reset() { for p in a b; do $P exec mtu-peer-$p ip link set wg0 mtu "$WG_MTU"; done; echo "reset: MTU $WG_MTU"; }
down() { $P rm -f -t 0 mtu-peer-a mtu-peer-b mtu-router >/dev/null 2>&1 || true; $P network rm mtu_a mtu_b >/dev/null 2>&1 || true; echo down; }

case "${1:-all}" in
    up) up ;; test) test_ ;; fix-mtu) fix_mtu ;; reset) reset ;; down) down ;;
    all) down >/dev/null; up; echo "== 1. as nordvpn-linux configures it (MTU $WG_MTU)"; test_
         fix_mtu; echo "== 2. with MTU 1400"; test_; down >/dev/null
         PROBING=1 up; echo "== 3. MTU $WG_MTU again, but TCP MTU probing on"; test_; down ;;
    *) echo "usage: $0 up|test|fix-mtu|reset|down|all" >&2; exit 2 ;;
esac
