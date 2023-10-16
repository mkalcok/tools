#!/bin/bash
HOST_PREFIX="micro"
NETWORK="microbr0"

function usage {
	echo "Initialize (or Teardown) 4 VMs using LXD to host Microcloud."
	echo ""
	echo "Initiation tasks performed:"
	echo "  * Create 4 VMs named 'micro-1' .. 'micro-4'."
	echo "  * Create 4 volumes named 'local1' .. 'local4' in default"
	echo "    storage pool and attach each to one VM for Microcloud's"
	echo "    local storage."
	echo "  * Create 3 volumes named 'remote1' .. 'remote3' in default"
	echo "    storage pool and attach them to first 3 VMs for Microcloud's"
	echo "    distributed storage."
	echo "  * Create bridged network 'microbr0' and attach VM's to it."
	echo "  * Install lxd, microovn, microceph and microcloud snaps in each VM."
	echo ""
	echo "Teardown cleans up LXD resources (VMs, volumes, network)"
	echo ""
	echo "Usage: ./microcloud-prepare.sh {init|teardown}"
}

# _wait_shell HOST
#
# Wait up to ~30s for LXD to be able to execute commands inside HOST
function _wait_shell() {
    local host=$1; shift
    local max_retry=30

    local i
    for (( i = 1; i <= max_retry; i++ )); do

        if lxc exec "$host" true; then
            break
            else
                echo "Waiting on $host to have active console ($i/$max_retry)"
                sleep 1;
        fi

    done
}

# _setup_disks PREFIX NUMBER
#
# Create NUMBER of LXD volumes in default storage pool with naming
# convention '"PREFIX""NUMBER"'
function _setup_disks {
	local name=$1; shift
	local num=$1; shift

	local i
	for (( i = 1; i <= num; i++ )); do
		lxc storage volume create default "$name""$i" --type block
	done
}

# _init_hosts NUMBER MAX_REMOTES
#
# Start NUMBER of LXD VMs. Each VM gets attached to network in $NETWORK.
# Each VM also gets attached one "local" volume for Microcloud's local storage
# and first 3 VMs get attached another "remote" volume for distributed storage.
function _init_hosts {
	local num=$1; shift
	local max_remote=$1; shift

	lxc network create microbr0 --type bridge

    local i
	for (( i = 1; i <= num; i++ )); do
		local host="$HOST_PREFIX"-"$i"
		local local_volume="local$i"
		
		lxc init ubuntu:jammy "$host" --vm --config limits.cpu=2 --config limits.memory=2GiB
		
		echo "Attaching $local_volume to $host"
		lxc storage volume attach default "$local_volume" "$host"
		
		if [ "$i" -le "$max_remote" ]; then
			local remote_volume="remote$i"
			echo "Attaching $remote_volume to $host"
			lxc storage volume attach default "$remote_volume" "$host"
		fi

		lxc config device add "$host" eth1 nic network="$NETWORK" name=eth1
		lxc start "$host"

        _wait_shell "$host"

		lxc exec "$host" -- ip link set enp6s0 up
		lxc exec "$host" -- sh -c "echo 0 > /proc/sys/net/ipv6/conf/enp6s0/accept_ra"

	done
}

# _setup_software NUMBER
#
# Install required snaps on each VM from 1 to NUMBER.
function _setup_software {
	local host_count=$1; shift

    local i
	for (( i = 1; i <= host_count; i++ )); do
		local host="$HOST_PREFIX"-"$i"
		lxc exec "$host" -- snap install microceph microovn microcloud
		lxc exec "$host" -- snap refresh lxd --channel=latest/stable
	done

}

# setup
#
# Bring up 4 LXD VMs and prepare them for hosting Microcloud
function setup {
	_setup_disks "local" 4
	_setup_disks "remote" 3
	_init_hosts 4 3
	_setup_software 4

}

# teardown
#
# Cleanup LXD resources created in setup function. This includes
#  * VMs
#  * volumes
#  * bridged network
function teardown {
    local i
	for (( i = 1; i <= 4; i++ )); do
		local host="$HOST_PREFIX"-"$i"
		echo "Deleting Microcloud instance $host"
		lxc delete --force "$host"

		lxc storage volume delete default "local$i"

		if [ "$i" -le 3 ]; then
			lxc storage volume delete default "remote$i"
		fi
	done

	lxc network delete "$NETWORK"
}

case "$1" in
	"init")
		setup
		;;
	"teardown")
		teardown
		;;
	*)
		usage
		;;
esac
