#!/bin/bash

set -o errexit -o pipefail

components="elasticsearch fluentd rsyslog-collector qpid-router kibana"

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

function _list_bitscout_containers(){
	docker ps -a --format="{{.ID}},{{.Image}},{{.Names}}" \
		| grep ',bitscout[/-]' \
		| awk -F ","  '{print $1}'
}

function _remove_docker_containers(){
	for container in `_list_bitscout_containers`; do
		docker rm $container
	done
}

function _remove_docker_image(){
	if docker images | grep $1; then
		docker rmi "$1"
	fi
}

function cleanup(){
	_remove_docker_containers
	for component in $components; do
		_remove_docker_image bitscout/$component
		_remove_docker_image bitscout/$component-app
	done
	docker rmi bitscout/efk-atomicapp
	[ "x`docker images | grep bitscout`" == "x" ]
}


