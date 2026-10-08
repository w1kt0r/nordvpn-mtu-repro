# Tools for the reproduction: WireGuard, iptables, a web server and a client.
FROM docker.io/library/debian:trixie
RUN export DEBIAN_FRONTEND=noninteractive && apt-get update \
 && apt-get install -y --no-install-recommends iproute2 iptables wireguard-tools python3 curl iputils-ping procps \
 && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
