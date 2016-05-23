#!/bin/sh

set -ex
prefix=${PREFIX:-${1:-viaq/}}
version=${VERSION:-${2:-latest}}
docker build --no-cache=false --pull=false -t "${prefix}rsyslog-perf-test:${version}" .

if [ -n "${PUSH:-$3}" ]; then
	docker push "${prefix}rsyslog-perf-test:${version}"
fi
