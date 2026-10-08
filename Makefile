# Meshnet MTU reproduction. Run `make` for the list of targets.

.DEFAULT_GOAL := help
.PHONY: help repro up test fix-mtu reset probing down nordvpn tarball

help:  ## show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "  Start with: make repro"

repro:  ## run all three scenarios (MTU 1420, MTU 1400, TCP MTU probing) and clean up
	./repro.sh all

up:  ## build and start the containers (MTU 1420, path drops packets > 1478 bytes)
	./repro.sh up

test:  ## measure the largest packet through the tunnel and try a 1 MB download
	./repro.sh test

fix-mtu:  ## set the tunnel MTU to 1400 on both peers (then: make test)
	./repro.sh fix-mtu

reset:  ## back to tunnel MTU 1420
	./repro.sh reset

probing:  ## restart with net.ipv4.tcp_mtu_probing=1 (then: make test)
	./repro.sh down
	PROBING=1 ./repro.sh up

down:  ## remove the containers and networks
	./repro.sh down

nordvpn:  ## the same with the NordVPN client in both peers (needs NORDVPN_TOKEN)
	@test -n "$$NORDVPN_TOKEN" || { echo "set NORDVPN_TOKEN to a NordVPN access token"; exit 1; }
	./nordvpn.sh all

tarball:  ## package this kit as ../nordvpn-mtu-repro.tar.gz
	git archive --format=tar.gz --prefix=nordvpn-mtu-repro/ -o ../nordvpn-mtu-repro.tar.gz HEAD
	@ls -l ../nordvpn-mtu-repro.tar.gz
