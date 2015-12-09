#!/bin/bash

set -o errexit -o pipefail

components="elasticsearch fluentd qpid-router kibana"

atomicrundir=bitscout-efk-app

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
	[ -d $atomicrundir ] ; rm $atomicrundir
	mkdir $atomicrundir
	cp efk-atomicapp/answers.conf $atomicrundir
	cd $atomicrundir
	atomic run bitscout/efk-atomicapp
	cd -
}

function turn_off(){
	docker stop `docker ps -q`
	[ -d $atomicrundir ] ; rm $atomicrundir
}

function _remove_docker_image(){
	docker rmi "$1"

}

function cleanup(){
	for component in $components; do
		_remove_docker_image bitscout/$component
		_remove_docker_image bitscout/$component-app
	done
	docker rmi bitscout/efk-atomicapp
	[ "x`docker images | grep bitscout`" == "x" ]
}


