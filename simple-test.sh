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

for app in fluentd elasticsearch kibana qpid-router rsyslog-collector ; do
    pushd docker-$app
    ./build-image.sh
    popd
done

USE_LINKS="--link viaq-elasticsearch"

# first, start elasticsearch
sudo rm -rf /var/lib/viaq
DB_IN_CONTAINER=1 sh -x docker-elasticsearch/run-container.sh

# wait for it to start
sleep 5

#USE_HOST_NETWORK="--net=host"

if [ -n "$USE_LINKS" ] ; then
    USE_ES_HOST="-e ES_HOST=viaq-elasticsearch"
elif [ -z "$USE_HOST_NETWORK" ] ; then
    dockeraddr=`ip addr|awk -F'[ /]+' '/inet .* docker0/ {print $3}'`
    USE_ES_HOST="-e ES_HOST=$dockeraddr"
fi
# next, start kibana
kibanaid=`docker run $USE_LINKS $USE_HOST_NETWORK $USE_ES_HOST -p 5601:5601 -d viaq/kibana:latest`
docker logs $kibanaid

# start qpid router
qpidid=`docker run -d --name viaq-qpid-router -p 5672:5672 viaq/qpid-router`
sleep 10
docker logs $qpidid

# start fluentd
fluentdid=`docker run -p 10514:10514/udp --link viaq-qpid-router $USE_LINKS $USE_HOST_NETWORK $USE_ES_HOST -e SYSLOG_LISTEN_PORT=10514 -d viaq/fluentd:latest`
sleep 5
docker logs $fluentdid

rsc=`docker run -p 5141:5141 -p 5141:5141/udp --link viaq-qpid-router $USE_LINKS $USE_HOST_NETWORK -e SYSLOG_LISTEN_PORT=5141 -d viaq/rsyslog-collector:latest`
sleep 5
