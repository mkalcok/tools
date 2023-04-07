#!/bin/bash

# lxc list --project snapcraft -f json | jq '.[].name' | xargs -I {} lxc info --project snapcraft {}

help()
{
	echo "Utility for mass deletion of LXC images in selected project."
	echo
	echo "Syntax: ./lxc.purge-project.sh [-h] <project>"
	echo "Options:"
	echo -e "-h\t Print help message"

}

if [ -z "$1" ]
then
	echo "Project name must be specified"
	help
	exit 1
fi

if [ "$1" == "-h" ]
then
	help
	exit 0
fi

if [ "$#" -gt 1 ]
then
	echo "Unexpected number of arguments."
	help
	exit 1
fi


echo Purging LXC project $1

lxc list --project $1 -f json | jq -r '.[].name' | while read line ; do
	echo Deleting container $line
	lxc delete --force --project $1 $line
done

