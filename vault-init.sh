#!/bin/bash
help () {
echo This script automates steps for inital vault unsealement described here:
echo https://charmhub.io/vault
echo
echo "Usage: ./vault-init [UNIT_NAME]"
echo
echo Argument UNIT_NAME is optional, if not supplied, default value "vault/0"
echo will be used.
echo
echo Requred tools:
echo ' - vault'
echo ' - jq'
echo ' - juju'
}

strip_quotes () {
    # Remove double-quotes from string
    echo $1 | sed -e "s/^\"//" -e "s/\"$//"
}

while getopts ":h" option; do
   case $option in
      h)
         help
         exit;;
   esac
done

VAULT_UNIT=${1:-"vault/0"}

# Find and export Vault unit public IP
IP_PATH=".applications.vault.units.\"$VAULT_UNIT\".\"public-address\""
RAW_ADDR=$(juju status vault --format=json | jq $IP_PATH)

if [ "$RAW_ADDR" == "null" ]; then
    echo Vault unit \"$VAULT_UNIT\" not found
    exit -1
fi
export VAULT_ADDR="http://$(strip_quotes $RAW_ADDR):8200"
echo Found vault unit at $VAULT_ADDR
exit

# Initiate vault to get unsealing keys
INIT_OUTPUT=$(vault operator init -key-shares=5 -key-threshold=3 -format=json)
INIT_KEYS=$(echo $INIT_OUTPUT | jq -c .unseal_keys_b64[])
ROOT_TOKEN=$(echo $INIT_OUTPUT | jq .root_token)
export VAULT_TOKEN=$(strip_quotes $ROOT_TOKEN)

# Unseal vault with initial keys
for KEY in $INIT_KEYS
do
    echo Unsealing Vault with key $KEY
    UNSEAL_RESULT=$(vault operator unseal -format=json $(strip_quotes $KEY))
    STATE=$(echo $UNSEAL_RESULT | jq .sealed)
    if [ "$STATE" == "false" ]; then
        echo Unsealed!
        break
    fi
    echo Still sealed.
done

# Create token for juju action
CHARM_TOKEN_OUTPUT=$(vault token create -ttl=1m -format=json)
CHARM_TOKEN=$(echo $CHARM_TOKEN_OUTPUT | jq .auth.client_token)

# Use juju to authorize charm
juju run-action --wait vault/leader authorize-charm token=$(strip_quotes $CHARM_TOKEN)

