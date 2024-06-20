#!/bin/bash

# Fill OVN SB and NB database with data to cause schema upgrades
# to take longer than heartbeat limit
#
# This script expects OVN to be deployed on LXC VMs called microcloud-X

VM_BASE_NAME="microcloud"
NB_APPCTL_CMD="microovn.ovn-appctl -t /var/snap/microovn/common/run/ovn/ovnnb_db.ctl"
SB_APPCTL_CMD="microovn.ovn-appctl -t /var/snap/microovn/common/run/ovn/ovnsb_db.ctl"
NB_CLUSTER_STATUS="$NB_APPCTL_CMD cluster/status OVN_Northbound 2>&1"
SB_CLUSTER_STATUS="$SB_APPCTL_CMD cluster/status OVN_Southbound 2>&1"
NB_SET_TIMER="$NB_APPCTL_CMD cluster/change-election-timer OVN_Northbound"
SB_SET_TIMER="$SB_APPCTL_CMD cluster/change-election-timer OVN_Southbound"
OVSDB_LIST_DP="microovn.ovsdb-client -f json dump \
               unix:/var/snap/microovn/common/run/ovn/ovnsb_db.sock \
               OVN_Southbound Datapath_Binding"
OVSDB_INSERT="microovn.ovsdb-client transact unix:/var/snap/microovn/common/run/ovn/ovnsb_db.sock"

function __log(){
    local msg=$1; shift
    echo $msg >&2
}

function __lxc_exec(){
    local target=$1; shift
    echo "lxc exec $target -- bash -c"
}

function __find_leader(){
    local vm_count=$1; shift
    
    local nb_leader=""
    local sb_leader=""

    local i
    for i in $(seq 1 $vm_count);do
        local vm_name="$VM_BASE_NAME-$i"

        __log "Looking for NB/SB leader on $vm_name"
        if $(__lxc_exec $vm_name) "$NB_CLUSTER_STATUS" | grep "Leader: self" > /dev/null; then
            nb_leader=$vm_name
            __log "NB leader found on $vm_name"
        fi
        
        if $(__lxc_exec $vm_name) "$SB_CLUSTER_STATUS" | grep "Leader: self" > /dev/null; then
            sb_leader=$vm_name
            __log "SB leader found on $vm_name"
        fi

        if [ -n "$nb_leader" ] && [ -n "$sb_leader" ];then
            break
        fi
    done

    if [ -z "$nb_leader" ];then
        __log "failed to local NB leader"
        exit 1
    fi

    if [ -z "$sb_leader" ];then
        __log "failed to local SB leader"
        exit 1
    fi

    echo "$nb_leader $sb_leader"
}

function __get_election_timer(){
    local target=$1; shift
    local status_cmd=$1; shift

    local raw_timer=$($(__lxc_exec $target) "$status_cmd" | grep "Election timer:")

    if [ -z "$raw_timer" ];then
        __log "Failed to get election timer on $target"
        echo "-1"
    else
        echo $raw_timer | awk '{print $3}'
    fi
    
}

function __lower_election_timer(){
    local nb_leader=$1; shift
    local sb_leader=$1; shift

    local nb_timer=1000000
    local sb_timer=1000000
    
    while [ $nb_timer -gt 1000 ] || [ $sb_timer -gt 1000 ]; do
        nb_timer=$(__get_election_timer "$nb_leader" "$NB_CLUSTER_STATUS")
        sb_timer=$(__get_election_timer "$sb_leader" "$SB_CLUSTER_STATUS")

        if [ $nb_timer -lt 0 ] || [ $sb_timer -lt 0 ]; then
            exit 1
        fi

        local new_nb_val="$(($nb_timer-1000))"
        if [ $nb_timer -ge 2000 ]; then
            __log "Setting NB timer to $new_nb_val"
            $(__lxc_exec "$nb_leader") "$NB_SET_TIMER $new_nb_val"
        fi

        local new_sb_val="$(($sb_timer-1000))"
        if [ $sb_timer -ge 2000 ]; then
            __log "Setting SB timer to $new_sb_val"
            $(__lxc_exec "$sb_leader") "$SB_SET_TIMER $new_sb_val"
        fi

        sleep 1
    done
}

function __stuff_sb_db(){
    local leader=$1; shift

    local dp_uuid=$($(__lxc_exec "$leader") "$OVSDB_LIST_DP" | jq -r '.data[0][0][1]')

    if [ -z $dp_uuid ];then
        __log "Failed to find Datapath"
        exit 1
    fi

    for third_oct in $(seq 1 15);do
        for second_oct in $(seq 1 254);do
            __log "Generating MAC_Binding for 1.$third_oct.$second_oct.1-254"
            local rows="[\"OVN_Southbound\""
            for first_oct in $(seq 1 254);do
                rows="$rows,\n"
                local ip="1.$third_oct.$second_oct.$first_oct"
                local row="{\"op\" : \"insert\", \"table\" : \"MAC_Binding\", \"row\":{\"logical_port\": \"foo\", \"ip\": \"$ip\", \"mac\": \"ff:ff:ff:ff\", \"datapath\": [\"uuid\",\"$dp_uuid\"]}}"
                rows="$rows$row"
            done
            __log "Inserting batch of MAC_Bindings"
            rows="$rows]"
            echo -e $rows > /tmp/ovn-stuffing
            $(__lxc_exec "$leader") "$OVSDB_INSERT '$(</tmp/ovn-stuffing)'"
        done
    done
}
leaders=$(__find_leader 4)
nb_leader=$(echo $leaders | awk '{print $1}')
sb_leader=$(echo $leaders | awk '{print $2}')

__lower_election_timer $nb_leader $sb_leader
__stuff_sb_db $sb_leader

