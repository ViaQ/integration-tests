#!/bin/bash

set -o errexit -o pipefail

components="elasticsearch fluentd qpid-router kibana"

function build_images(){
	for component in $components; do
		build_image "docker-$component"
	done
}

function build_image(){
	local repo="$1"
	[ -d $repo ] || git clone https://github.com/BitScoutOrg/$repo
	cd $repo
	git pull --rebase
	./build-image.sh
	cd -
}

function cleanup(){
	for component in $components; do
		docker rmi bitscout/$component
		docker rmi bitscout/$component-app
	done
	[ "x`docker images | grep bitscout`" == "x" ]
}

set -x
build_images # later on we should just pull from docker hub? (currently missing *-app on dockerhub)
# TODO build nulecule stuff
# TODO turn on
# TODO test basic scenario
# TODO turn off
cleanup
