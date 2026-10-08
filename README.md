# Meshnet MTU reproduction

A self-contained reproduction, in rootless or rootful Podman, of large TCP
transfers stalling over NordVPN Meshnet on Linux when the network path to a
peer carries slightly smaller packets than the tunnel MTU and drops oversized
ones without sending ICMP "fragmentation needed".

## Background

nordvpn-linux sets the tunnel MTU to the default-route interface MTU minus 80
(`daemon/vpn/mtu.go`, `WireguardHeaderSize = 80`); on a normal 1500-byte LAN that
is 1420. On a real path we measured a limit of 1418 bytes inside the tunnel,
with oversized packets dropped silently. Small requests work; any transfer that
uses full-size packets stalls forever. `ip link set dev nordlynx mtu 1400`
fixes it immediately, but there is no setting to make that persistent.

## Topology

```
peer-a 10.91.1.10 --- net_a --- router --- net_b --- peer-b 10.91.2.10
```

The router forwards between the two networks and silently drops every packet
longer than `PATH_MAX` (default 1478 bytes outer, the measured value plus the
60-byte WireGuard/IPv4 overhead). No ICMP is generated. Everything else is
standard. All addresses are private test ranges.

## 1. Mechanism, no account needed: `./repro.sh all`

Plain kernel WireGuard between the peers at MTU 1420. Runs in about a minute.

Output on our machine:

```
== 1. as nordvpn-linux configures it (MTU 1420)
--- largest packet through the tunnel (Don't Fragment ping): 1408 bytes; tunnel MTU: 1420
--- download 1 MB through the tunnel (15 s limit):
    HTTP 200, 0 of 1048576 bytes in 15.002230 s
== 2. with MTU 1400
--- largest packet through the tunnel (Don't Fragment ping): 1400 bytes; tunnel MTU: 1400
--- download 1 MB through the tunnel (15 s limit):
    HTTP 200, 1048576 of 1048576 bytes in 0.021958 s
== 3. MTU 1420 again, but TCP MTU probing on
--- largest packet through the tunnel (Don't Fragment ping): 1408 bytes; tunnel MTU: 1420
--- download 1 MB through the tunnel (15 s limit):
    HTTP 200, 1048576 of 1048576 bytes in 6.388937 s
```

Kernel WireGuard pads packets to multiples of 16 bytes, so the edge shows as
1408 here instead of 1418; the stall is the same. The response headers arrive
(small packets), the body does not.

## 2. With the NordVPN client: `NORDVPN_TOKEN=<access token> ./nordvpn.sh all`

Same topology, but both peers run nordvpn-linux 5.4.0 with Meshnet, signed in
with the same access token (two devices of one account). The client sets the
`nordlynx` MTU itself. The drop rule applies only between the two peer
networks, so NordVPN's API and relays are unaffected; if Meshnet chooses a
relayed connection, the drop rule is bypassed and the stall will not show.

This variant was built and its daemon start was checked, but it was not run
end to end by the reporter (it needs an access token).

## Commands

```
./repro.sh up            build and start the mechanism repro
./repro.sh test          measure the edge and try the 1 MB download
./repro.sh fix-mtu       set the tunnel MTU to 1400 on both peers
./repro.sh reset         back to MTU 1420
PROBING=1 ./repro.sh up  start the peers with net.ipv4.tcp_mtu_probing=1
./repro.sh down          remove containers and networks
PATH_MAX=1450 WG_MTU=1420 ./repro.sh all    other sizes
```

Requires Podman and the WireGuard kernel module on the host. On Ubuntu the
host's AppArmor profile for `wg` only allows key files under `/etc/wireguard`,
which is where the script puts them.

## Suggested fixes

1. Clamp TCP MSS on `nordlynx` with a margin, or default to a slightly lower
   MTU (scenario 2 shows 1400 working).
2. A persistent setting, for example `nordvpn set mtu <value>`.
3. Enable TCP MTU probing for the tunnel, or probe the path MTU per Meshnet
   peer (scenario 3 shows probing recovering, slowly).
