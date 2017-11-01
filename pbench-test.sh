#!/bin/bash

# Script to run openshift-test as a pbench user benchmark.
# This test assumes pbench is installed.
# After the data is collected it can be pushed to server using pbench-move-results

if [ "$EUID" -ne 0 ] ; then
    echo Script must be run under root.
    exit
fi

set -euxo pipefail

if ! rpm -q pbench-agent ; then
    if [ ! -f /etc/yum.repos.d/pbench.repo ] ; then
        curl -s https://copr.fedorainfracloud.org/coprs/ndokos/pbench/repo/epel-7/ndokos-pbench-epel-7.repo > /etc/yum.repos.d/pbench.repo
    fi
    yum -y install pbench-agent
fi

if [ ! -d /var/lib/pbench-agent/tools-default ] ; then
    mkdir -p /var/lib/pbench-agent/tools-default
fi

. /opt/pbench-agent/profile

export USE_FLUENTD=${USE_FLUENTD:-true}
export NMESSAGES=${NMESSAGES:-5000}
export NPROJECTS=${NPROJECTS:-1}
#export SKIP_MESSAGES_TEST=${SKIP_MESSAGES_TEST:-true}

COLLECTOR_TYPE=rsyslog

if [ "$USE_FLUENTD" = "true" ] ; then
    COLLECTOR_TYPE=fluentd
fi

testname=test-${COLLECTOR_TYPE}-${NMESSAGES}-${NPROJECTS}
nohup pbench-user-benchmark --conf=$testname ./openshift-test.sh > $testname.log 2>&1 &

# pbench-kill-tools
# pbench-stop-tools
# pbench-move-results
