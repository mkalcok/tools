VM_BASE_NAME=microcloud
# second interface name may change based on how the OS decides to name it
IF_NAME=enp6s0

function usage(){
  echo "Helper script to bootstrap and teardown LXC VMs that are ready for microcloud deployment."
}

function __wait_vm(){
  local vm_name=$1; shift
  while :
  do
	  echo "Waiting for $vm_name to start"
    if ! lxc info $vm_name | grep "Processes: -1" > /dev/null; then
      echo "VM $vm_name started."
      break
    fi
    sleep 1
  done
  
  echo "Waiting for $vm_name to initialize"
  lxc exec $vm_name -- bash -c 'cloud-init status --wait && snap wait system seed.loaded'
}


function __install_prerequisites(){
  local vm_name=$1; shift
  
  lxc exec $vm_name -- bash -c 'snap install microovn microceph lxd microcloud'
}

function __ensure_network(){
  # create microcloud overlay network for OVN if it does not exist
  if ! lxc network info microcloud > /dev/null; then
      lxc network create microcloud ipv4.address=none ipv6.address=none -t bridge
  fi
}

function start_microcloud(){
  local cluster_size=$1; shift

  __ensure_network

  local i
  for i in $(seq 1 $cluster_size)
  do
    local vm_name=$VM_BASE_NAME-$i
    lxc launch ubuntu:noble $vm_name --vm --config limits.cpu=4 --config limits.memory=4GiB
    __wait_vm $vm_name

    lxc storage volume create default $vm_name-ceph size=5GiB --type block
    lxc storage volume attach default $vm_name-ceph $vm_name

    lxc network attach microcloud $vm_name
    lxc exec $vm_name ip link set dev $IF_NAME up
    
    __install_prerequisites $vm_name
  done
}

function teardown_microcloud(){
  local cluster_size=$1; shift

  local i
  for i in $(seq 1 $cluster_size)
  do
    local vm_name=$VM_BASE_NAME-$i

    lxc delete --force $vm_name
    lxc storage volume delete default $vm_name-ceph
  done
}

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi

cmd_="$1"; shift

case "$cmd_" in
  "start")
    start_microcloud "$@"
    ;;
  "teardown")
    teardown_microcloud "$@"
    ;;
  *)
    usage
    ;;
esac

