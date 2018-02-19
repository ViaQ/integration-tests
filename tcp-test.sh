#!/bin/sh
set -o errexit

for id in `docker ps -q` ; do
    if [ -n "$id" ] ; then
        docker stop $id
    fi
done
for id in `docker ps -qa` ; do
    if [ -n "$id" ] ; then
        docker rm $id
    fi
done

for app in fluentd rsyslog-collector ; do
    pushd docker-$app
    ./build-image.sh
    popd
done

# start fluentd
fluentdid=`docker run -p 20514:20514/tcp --name viaq-fluentd -e SYSLOG_LISTEN_PORT=10514 -d viaq/fluentd:latest`
sleep 5
docker logs $fluentdid

rsc=`docker run -p 5141:5141 -p 5141:5141/udp --link viaq-fluentd -e SYSLOG_LISTEN_PORT=5141 -d viaq/rsyslog-collector:latest`
sleep 5
