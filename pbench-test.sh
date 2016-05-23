#!/bin/bash

# Script to run openshift-test as a pbench user benchmark.
# This test assumes pbench is installed.
# After the data is collected it can be pushed to server using pbench-move-results

if [ "$EUID" -ne 0 ] ; then
    echo Script must be run under root.
    exit
fi

export USE_FLUENTD=${USE_FLUENTD:-true}
export NMESSAGES=${NMESSAGES:-5000}
export NPROJECTS=${NPROJECTS:-1}
export NSIZE=${NSIZE:-5}
export SKIP_MESSAGES_TEST=${SKIP_MESSAGES_TEST:-true}

COLLECTOR_TYPE=rsyslog

if [ "$USE_FLUENTD" = "true" ] ; then
    COLLECTOR_TYPE=fluentd
fi

nohup pbench-user-benchmark --conf=test-${NMESSAGES}-${COLLECTOR_TYPE} ./openshift-test.sh > log.log 2>&1 &

# pbench-kill-tools
# pbench-stop-tools
# pbench-move-results
