#!/bin/sh

set -euxo pipefail

testdir=`dirname $0`
pushd $testdir

USE_FLUENTD=${USE_FLUENTD:-true}
USE_GDB=${USE_GDB:-false}
USE_JOURNAL=${USE_JOURNAL:-false}
SKIP_MESSAGES_TEST=${SKIP_MESSAGES_TEST:-false}

if [ "$USE_JOURNAL" = "true" ] ; then
    rpm -q systemd-journal-gateway || sudo dnf -y install systemd-journal-gateway || \
        sudo yum -y install systemd-journal-gateway || {
            echo Error: please install the package systemd-journal-gateway
            exit 1
        }
fi

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

workdir=`mktemp -d`
mkdir -p $workdir
confdir=$workdir/config
datadir=$workdir/data
mkdir -p $confdir
mkdir -p $datadir/docker
sudo chown -R $USER $workdir
sudo chcon -Rt svirt_sandbox_file_t $workdir

orig=$workdir/orig
result=$workdir/result
fluentd_syslog_input=openshift-fluentd-syslog-tail.conf
rsyslog_syslog_input=rsyslog-input-file.conf
rsyslog_bindmount=
if [ "$USE_JOURNAL" = "true" ] ; then
    mkdir -p $datadir/journal
    systemlog=$datadir/journal/messages.journal
    fluentd_syslog_input=openshift-fluentd-syslog-journal.conf
    rsyslog_syslog_input=rsyslog-input-journal.conf
    rsyslog_bindmount="-v $datadir/journal:/run/log/journal"
else
    systemlog=$datadir/messages
fi

cleanup() {
    out=$?
#    docker logs $collectorid > collector.log 2>&1
    if [ -n "$workdir" -a -d "$workdir" ] ; then
#        if [ $out -ne 0 ] ; then
            ls -R -alrtF $workdir
#        fi
        rm -rf "$workdir"
    fi
}

trap "exit" INT TERM
trap "cleanup" EXIT

wait_until_cmd() {
    ii=$2
    interval=${3:-10}
    while [ $ii -gt 0 ] ; do
        $1 && break
        sleep $interval
        ii=`expr $ii - $interval`
    done
    if [ $ii -le 0 ] ; then
        return 1
    fi
    return 0
}

# $1 - es hostname
# $2 - project name (e.g. logging, test, .operations, etc.)
# $3 - _count or _search
# $4 - field to search
# $5 - search string
# $6 - extra params e.g. '&fields=message&size=1000'
# stdout is the JSON output from Elasticsearch
# stderr is curl errors
curl_es() {
    curl --connect-timeout 1 -s \
       http://${1}:9200/${2}*/${3}\?q=${4}:"${5}""${6:-}"
}

get_count_from_json() {
    python -c 'import json, sys; print json.loads(sys.stdin.read())["count"]'
}

# return true if the actual count matches the expected count, false otherwise
# $1 - es hostname
# $2 - project name (e.g. logging, test, .operations, etc.)
# $3 - field to search
# $4 - search string
# $5 - expected count
test_count_expected() {
    myfield=${myfield:-message}
    nrecs=`curl_es $1 $2 _count $3 $4 | get_count_from_json`
    test "$nrecs" = $5
}

format_syslog_message() {
    # $1 - full or short
    # $2 - $NFMT
    # $3 - $EXTRAFMT
    # $4 - $prefix
    # $5 - $ii
    if [ "$1" = "full" ] ; then
        printf "%s %s %s[%d]: %s-$2 $3\n" "$(date -u +'%b %d %H:%M:%S')" `hostname -s` \
               $4 $$ $4 $5 1
    else
        printf "%s-$2 $3\n" $4 $5 1
    fi
}

# get the date in utc Z format instead of regular -Ins format
get_date() {
    date -u +%FT%T.%NZ
}

format_json_message() {
    # $1 - full or short
    # $2 - $NFMT
    # $3 - $EXTRAFMT
    # $4 - $prefix
    # $5 - $ii
    msg=`printf "%s-$2 $3" $4 $5 1`
    if [ "$1" = "full" ] ; then
        printf '{"log":"%s\\n","stream":"stdout","time":"%s"}\n' "$msg" "`get_date`"
    else
        printf "%s\n" "$msg"
    fi
}

get_journal_timestamp() {
    # microseconds since epoch
    date -u +%s%6N
}

# journal -o export format for use with
# /usr/lib/systemd/systemd-journal-remote - -o /path/to/log.journal
# __CURSOR=s=f689c3b9b8dc4465acd22433bde89aed;i=71f60;b=0937011437e44850b3cb5a615345b50f;m=d3bafda0f;t=5330b9fab5ca6;x=244e23370340b59b
# _SOURCE_REALTIME_TIMESTAMP=1431439843797660
# __REALTIME_TIMESTAMP=1463499900017830
# __MONOTONIC_TIMESTAMP=56835955215
# _BOOT_ID=0937011437e44850b3cb5a615345b50f
# _UID=1000
# _GID=1000
# _CAP_EFFECTIVE=0
# _SYSTEMD_OWNER_UID=1000
# _SYSTEMD_SLICE=user-1000.slice
# _MACHINE_ID=68fe516b647f4d0fb5b0439d57b79344
# _HOSTNAME=localhost.localdomain
# _TRANSPORT=stdout
# PRIORITY=4
# _AUDIT_SESSION=1
# _AUDIT_LOGINUID=1000
# _SYSTEMD_CGROUP=/user.slice/user-1000.slice/session-1.scope
# _SYSTEMD_SESSION=1
# _SYSTEMD_UNIT=session-1.scope
# _SELINUX_CONTEXT=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
# SYSLOG_FACILITY=3
# CODE_FILE=../src/core/manager.c
# CODE_LINE=1761
# CODE_FUNCTION=process_event
# SYSLOG_IDENTIFIER=firefox.desktop
# _COMM=firefox
# _EXE=/usr/lib64/firefox/firefox
# _CMDLINE=/usr/lib64/firefox/firefox -new-instance -P default
# MESSAGE=Failed to open VDPAU backend libvdpau_va_gl.so: cannot open shared object file: No such file or directory
# _PID=2685
format_journal_message() {
    # $1 - full or short
    # $2 - $NFMT
    # $3 - $EXTRAFMT
    # $4 - $prefix
    # $5 - $ii
    fac=1
    sev=2
    msg=`printf "%s-$2 $3" $4 $5 1`
    ts=`get_journal_timestamp`
    hn=`hostname -s`
    if [ "$1" = "full" ] ; then
        tee -a /tmp/junk <<EOF
_SOURCE_REALTIME_TIMESTAMP=$ts
__REALTIME_TIMESTAMP=$ts
_BOOT_ID=0937011437e44850b3cb5a615345b50f
_UID=1000
_GID=1000
_HOSTNAME=$hn
SYSLOG_IDENTIFIER=$4
SYSLOG_FACILITY=$fac
_COMM=$4
_PID=$$
MESSAGE=$msg

EOF
    else
        echo "$msg"
    fi
}

# number of projects, number size, printf format
NPROJECTS=${NPROJECTS:-10}
NPSIZE=${NPSIZE:-2}
NPFMT=${NPFMT:-"%0${NPSIZE}d"}

podprefix="this-is-pod-"
projprefix="this-is-project-"
contprefix="this-is-container-"
format_json_filename() {
    # $1 - $ii
    printf "%s${NPFMT}_%s${NPFMT}_%s${NPFMT}-%s.log\n" "$podprefix" $1 "$projprefix" $1 "$contprefix" $1 "`echo $1 | sha256sum | awk '{print $1}'`"
}

pushd ../docker-elasticsearch
./build-image.sh
popd

DB_IN_CONTAINER=1 sh -x $testdir/../docker-elasticsearch/run-container.sh

# make a bunch of container log file names in $datadir
# name looks like this:
# name-of-pod_name-of-project_container-name-64hexchars.log
# contents are in JSON format like this:
##
# {"log":"here is where the actual output goes\n","stream":"stderr","time":"2016-04-26T17:09:37.759913885Z"}
# {"log":"another message\n","stream":"stdout","time":"2016-04-26T17:09:38.759913885Z"}

# number of messages per file
NMESSAGES=${NMESSAGES:-10}
# number size e.g. log base 10 of $NMESSAGES
NSIZE=${NSIZE:-2}
# printf format for message number
NFMT=${NFMT:-"%0${NSIZE}d"}
# size of each message - number of bytes to write to each line of the logger file, not
# the actual size of the JSON that is stored into ES
MSGSIZE=${MSGSIZE:-200}

ii=1
prefix=`uuidgen`
# need $MSGSIZE - (36 + "-" + $NSIZE + " ") bytes
n=`expr $MSGSIZE - 36 - 1 - $NSIZE - 1`
EXTRAFMT=${EXTRAFMT:-"%0${n}d"}
if [ "$USE_JOURNAL" = "true" ] ; then
    formatter=format_journal_message
    sysfilter() {
        /usr/lib/systemd/systemd-journal-remote - -o $systemlog
    }
else
    formatter=format_syslog_message
    sysfilter() {
        cat >> $systemlog
    }
fi
while [ $ii -le $NMESSAGES ] ; do
    # direct to /var/log/messages format
    $formatter full "$NFMT" "$EXTRAFMT" "$prefix" "$ii" | sysfilter
    $formatter short "$NFMT" "$EXTRAFMT" "$prefix" "$ii" >> $orig
    jj=1
    while [ $jj -le $NPROJECTS ] ; do
        fn=`format_json_filename $jj`
        format_json_message full "$NFMT" "$EXTRAFMT" "$prefix" "$ii" >> $datadir/docker/$fn
        format_json_message short "$NFMT" "$EXTRAFMT" "$prefix" "$ii" >> $orig
        jj=`expr $jj + 1`
    done
    ii=`expr $ii + 1`
done

if [ "$USE_FLUENTD" = "true" ] ; then
    pushd ../docker-fluentd
    ./build-image.sh
    popd
    # copy fluentd config to config dir
    cp openshift-fluentd.conf $confdir/fluent.conf
    cp $fluentd_syslog_input $confdir/syslog-input.conf
    # run fluentd with the config dir mounted as /etc/fluentd
    STARTTIME=$(date +%s)
    collectorid=`docker run -e RUBY_SCL_VER=rh-ruby22 -p 5141:5141/udp -p 24220:24220 -v $datadir:/datadir -v $confdir:/etc/fluent --link viaq-elasticsearch -e ES_HOST=viaq-elasticsearch -e OPS_HOST=viaq-elasticsearch -e ES_PORT=9200 -e OPS_PORT=9200 -e DATA_DIR=/datadir -e SYSLOG_LISTEN_PORT=5141 -d viaq/fluentd:latest`
else
    pushd ../docker-rsyslog-collector
    ./build-image.sh
    popd
    pushd rsyslog-perf-test
    cp $rsyslog_syslog_input syslog-input-filter.conf
    ./build-image.sh
    popd
    # run rsyslog with the config dir mounted as /etc/rsyslog.d
    STARTTIME=$(date +%s)
    if [ "$USE_GDB" != false ] ; then
        docker run -p 5141:5141/udp $rsyslog_bindmount -v $datadir:/datadir --link viaq-elasticsearch -e ES_HOST=viaq-elasticsearch -e SYSLOG_LISTEN_PORT=5141 -it viaq/rsyslog-perf-test:latest gdb --args /usr/sbin/rsyslogd -n
    else
        collectorid=`docker run -p 5141:5141/udp $rsyslog_bindmount -v $datadir:/datadir --link viaq-elasticsearch -e ES_HOST=viaq-elasticsearch -e SYSLOG_LISTEN_PORT=5141 -d viaq/rsyslog-perf-test:latest`
    fi
fi

count_ge_nmessages() {
    curl localhost:24220/api/plugins.json
    curcount=`curl_es $myhost $myproject _count $myfield "$mymessage" | get_count_from_json`
    echo count $curcount time $(date +%s)
    test $curcount -ge $NMESSAGES
}

echo waiting for $NMESSAGES messages in .operations and $NPROJECTS projects in elasticsearch

myhost=localhost myproject=.operations myfield=ident mymessage=$prefix wait_until_cmd count_ge_nmessages 520 5 || {
    echo error: $NMESSAGES messages not found in .operations
    curl_es localhost .operations _search ident $prefix | python -mjson.tool
    exit 1
}

ii=1
while [ $ii -le $NPROJECTS ] ; do
    myproject=`printf "%s${NPFMT}" $projprefix $ii`
    myhost=localhost myproject=$myproject myfield=message mymessage=$prefix wait_until_cmd count_ge_nmessages 520 5 || {
        echo error: $NMESSAGES messages not found in $myproject
        curl_es localhost $myproject _search message $prefix | python -mjson.tool
        exit 1
    }
done

# now total number of records >= $startcount + $NMESSAGES
# mark time
MARKTIME=$(date +%s)

if [ "$SKIP_MESSAGES_TEST" = "true" ] ; then
    echo Skipping tests, code will terminate in 30 sec.
    sleep 30
    exit
fi

echo duration `expr $MARKTIME - $STARTTIME`

# search ES and extract the messages
#esmessages=`mktemp`
total=`expr $NMESSAGES \* \( $NPROJECTS + 1 \)`
curl_es localhost "" _search message $prefix "&fields=message&size=$total" | \
    python -c 'import json, sys; print "\n".join([ii["fields"]["message"][0] for ii in json.loads(sys.stdin.read())["hits"]["hits"]])' | \
    grep -v '^$' | \
    sort -n > $result

sort -n $orig > $orig.sorted

diff $orig.sorted $result
