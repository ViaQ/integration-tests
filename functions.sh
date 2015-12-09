#!/bin/bash

set -o errexit -o pipefail

components="elasticsearch fluentd qpid-router kibana"

function build_images(){
	for component in $components; do
		build_image "docker-$component"
		build_image "nulecule-$component"
	done
	build_image "efk-atomicapp"
}

function build_image(){
	local repo="$1"
	[ -d $repo ] || git clone https://github.com/BitScoutOrg/$repo
	cd $repo
	git pull --rebase
	./build-image.sh
	cd -
}

function turn_on(){
	local rundir=bitscout-efk-app
	mkdir $rundir
	cp efk-atomicapp/answers.conf $rundir
	cd $rundir
	atomic run bitscout/efk-atomicapp
	cd -
}

function turn_off(){
	docker stop `docker ps -q`
}

function cleanup(){
	rm bitscout-efk-app
	for component in $components; do
		docker rmi bitscout/$component
		docker rmi bitscout/$component-app
	done
	docker rmi bitscout/efk-atomicapp
	[ "x`docker images | grep bitscout`" == "x" ]
}


