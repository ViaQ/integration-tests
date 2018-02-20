#!/bin/bash

set -euxo pipefail

testdir=`dirname $0`
pushd $testdir

USE_FLUENTD=${USE_FLUENTD:-true}
USE_GDB=${USE_GDB:-false}
ES_VER=${ES_VER:-2.4.4}
DEBUG_FLUENTD=false
# if true, use the journal for system messages/.operations
# if false, use /var/log/messages
USE_JOURNAL_FOR_SYSTEM=${USE_JOURNAL_FOR_SYSTEM:-true}
# if true, use the journal for container messages
# if false, use json file
USE_JOURNAL_FOR_CONTAINERS=${USE_JOURNAL_FOR_CONTAINERS:-false}
if [ $USE_JOURNAL_FOR_SYSTEM = true -o $USE_JOURNAL_FOR_CONTAINERS = true ] ; then
    USE_JOURNAL=true
else
    USE_JOURNAL=false
fi
# so, something broke somewhere about using systemd-journal-remote on Fedora
# to generate a journal that can be read on EL7 - it used to work (maybe
# on F23?) but on F24 it does not work - so, have to run systemd-journal-remote
# in a centos7 container to generate the messages.journal file in a format that
# can be read by fluentd
USE_CONTAINER_FOR_JOURNAL_FORMAT=${USE_CONTAINER_FOR_JOURNAL_FORMAT:-true}
# this will grab every message stored in Elasticsearch and compare it against
# the original written to file/journal - skip this if your message count
# exceeds 9999
SKIP_MESSAGES_TEST=${SKIP_MESSAGES_TEST:-true}

if [ "$USE_JOURNAL" = "true" ] ; then
    if [ "${USE_CONTAINER_FOR_JOURNAL_FORMAT:-}" != true ] ; then
        test -x /usr/lib/systemd/systemd-journal-remote || \
            sudo dnf -y install /usr/lib/systemd/systemd-journal-remote || {
                echo Error: please install the package containing /usr/lib/systemd/systemd-journal-remote
                exit 1
            }
    fi
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

workdir=$( mktemp -d -p /var/tmp )
mkdir -p $workdir
confdir=$workdir/config
datadir=$workdir/data
mkdir -p $confdir
mkdir -p $datadir/containers
mkdir -p $datadir/rsyslog
sudo chown -R $USER $workdir
sudo chcon -R unconfined_u:object_r:svirt_sandbox_file_t:s0 $workdir

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
    rsyslog_bindmount="-v $datadir/journal:/var/log/journal"
else
    systemlog=$datadir/messages
fi
if [ $USE_JOURNAL_FOR_CONTAINERS = false ] ; then
    fluentd_docker_input=openshift-fluentd-json-file.conf
fi

cleanup() {
    out=$?
    docker logs $collectorid > collector.log 2>&1
    if [ -n "$workdir" -a -d "$workdir" ] ; then
        if [ $out -ne 0 ] ; then
            ls -R -alrtF $workdir
        fi
        rm -rf "$workdir"
    fi
    exit $out
}

trap "exit" INT TERM
trap "cleanup" EXIT

wait_until_cmd() {
    local ii=$2
    local interval=${3:-10}
    while [ $ii -gt 0 ] ; do
        $1 && break
        sleep $interval
        ii=$( expr $ii - $interval )
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
       http://${1}:9200/${2}*/${3}\?size=9000\&q=${4}:"${5}""${6:-}"
}

curl_es_ext() {
    local host=$1 ; shift
    local url="$1"; shift
    curl --connect-timeout 1 -s \
       "http://${host}:9200${url}" "$@"
}

get_count_from_json() {
    python -c 'import json, sys; print json.load(sys.stdin).get("count", 0)'
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

format_json_file() {
    local full=$1
    local nrecs=$2
    local prefix=$3
    local msgsize=$4
    local startts=$( date -u +%s%N )
    python -c 'import sys
from datetime import datetime
full = sys.argv[1]
nrecs = int(sys.argv[2])
width = len(sys.argv[2])
prefix = sys.argv[3]
msgsize = int(sys.argv[4])
tsstr = sys.argv[5]
ts = int(tsstr)

if full == "full":
  template = "{{{{\"log\":\"{prefix}-{{ii:0{width}d}} {{ii:0{msgsize}d}}\\n\",\"stream\":\"stdout\",\"time\":\"{{ts}}\",\"ident\":\"{prefix}\"}}}}\n".format(prefix=prefix, width=width, msgsize=msgsize)
else:
  template = "{prefix}-{{ii:0{width}d}} {{ii:0{msgsize}d}}\n".format(prefix=prefix, width=width, msgsize=msgsize)
for ii in xrange(1, nrecs + 1):
  tsstr = datetime.utcfromtimestamp(ts/1000000000.0).isoformat() + "000Z"
  sys.stdout.write(template.format(ts=tsstr, ii=ii))
  ts = ts + 1000
' $full $nrecs $prefix $msgsize $startts
}

# create a journal which has N records - output is journalctl -o export format
# suitable for piping into systemd-journal-remote
# if nproj is given, also create N records per project
format_journal() {
    local nrecs=$1
    local prefix=$2
    local msgsize=$3
    local needops=$4
    local needapps=$5
    local hn=$( hostname -s )
    local startts=$( date -u +%s%6N )
    python -c 'import sys
nrecs = int(sys.argv[1])
width = len(sys.argv[1])
prefix = sys.argv[2]
msgsize = int(sys.argv[3])
needops = sys.argv[4].lower() == "true"
needapps = sys.argv[5].lower() == "true"
hn = sys.argv[6]
tsstr = sys.argv[7]
ts = int(tsstr)
pid = sys.argv[8]
if len(sys.argv) > 9:
  nproj = int(sys.argv[9])
  projwidth = len(sys.argv[9])
  contprefix = sys.argv[10]
  podprefix = sys.argv[11]
  projprefix = sys.argv[12]
  poduuid = sys.argv[13]
  contfields = """CONTAINER_NAME=k8s_{contprefix}{{jj:0{projwidth}d}}.deadbeef_{podprefix}{{jj:0{projwidth}d}}_{projprefix}{{jj:0{projwidth}d}}_{poduuid}_abcdef01
CONTAINER_ID={xx}
CONTAINER_ID_FULL={yy}
""".format(contprefix=contprefix,projwidth=projwidth,podprefix=podprefix,projprefix=projprefix,poduuid=poduuid,xx="1"*12,yy="1"*64)
else:
  nproj = 0
  contfields = ""

template = """_SOURCE_REALTIME_TIMESTAMP={{ts}}
__REALTIME_TIMESTAMP={{ts}}
_BOOT_ID=0937011437e44850b3cb5a615345b50f
_UID=1000
_GID=1000
_HOSTNAME={hn}
SYSLOG_IDENTIFIER={prefix}
SYSLOG_FACILITY=1
_COMM={prefix}
_PID={pid}
_TRANSPORT=stderr
PRIORITY=3
""".format(prefix=prefix, hn=hn, width=width, pid=pid, contfields=contfields)

template = template + """MESSAGE={prefix}-{{ii:0{width}d}} {msg:0{msgsize}d}
""".format(prefix=prefix, width=width, msgsize=msgsize, msg=0)

conttemplate = template + contfields

for ii in xrange(1, nrecs + 1):
  if needops:
    sys.stdout.write(template.format(ts=ts, ii=ii) + "\n")
    ts = ts + 1
  if needapps:
    for jj in xrange(1, nproj + 1):
      sys.stdout.write(conttemplate.format(ts=ts, ii=ii, jj=jj) + "\n")
      ts = ts + 1
' $nrecs $prefix $msgsize $USE_JOURNAL_FOR_SYSTEM $USE_JOURNAL_FOR_CONTAINERS $hn $startts $$ ${NPROJECTS:-0} ${contprefix:-""} ${podprefix:-""} ${projprefix:-""} $( uuidgen )
}

format_external_project() {
    local nrecs=$1
    local prefix=$2
    local msgsize=$3
    local hn=$( hostname -s )
    local startts=$( date -u +%s.%6N )
    python -c 'import sys,json
from datetime import datetime,timedelta
nrecs = int(sys.argv[1])
width = len(sys.argv[1])
prefix = sys.argv[2]
msgsize = int(sys.argv[3])
hn = sys.argv[4]
tsstr = sys.argv[5]
ts = datetime.fromtimestamp(float(tsstr))
usec = timedelta(microseconds=1)
msgtmpl = "{prefix}-{{ii:0{width}d}} {msg:0{msgsize}d}".format(prefix=prefix, width=width, msgsize=msgsize, msg=0)
hsh = {"hostname": hn, "level": "err", "ident": prefix}
for ii in xrange(1, nrecs + 1):
  hsh["@timestamp"] = ts.isoformat()+"+00:00"
  hsh["message"] = msgtmpl.format(ii=ii)
  sys.stdout.write(json.dumps(hsh, indent=None, separators=(",", ":")) + "\n")
  ts = ts + usec
' $nrecs $prefix $msgsize $hn $startts
}

# number of projects, number size, printf format
NPROJECTS=${NPROJECTS:-10}
NPSIZE=${NPSIZE:-$( echo $NPROJECTS | wc -c )}
NPFMT=${NPFMT:-"%0${NPSIZE}d"}

podprefix="this-is-pod-"
projprefix="this-is-project-"
contprefix="this-is-container-"
format_json_filename() {
    # $1 - $ii
    printf "%s${NPFMT}_%s${NPFMT}_%s${NPFMT}-%s.log\n" "$podprefix" $1 "$projprefix" $1 "$contprefix" $1 "`echo $1 | sha256sum | awk '{print $1}'`"
}

pushd ../docker-elasticsearch
ES_VER=$ES_VER ./build-image.sh
popd

ES_VER=$ES_VER DB_IN_CONTAINER=1 sh -x $testdir/../docker-elasticsearch/run-container.sh

# make a bunch of container log file names in $datadir
# name looks like this:
# name-of-pod_name-of-project_container-name-64hexchars.log
# contents are in JSON format like this:
##
# {"log":"here is where the actual output goes\n","stream":"stderr","time":"2016-04-26T17:09:37.759913885Z"}
# {"log":"another message\n","stream":"stdout","time":"2016-04-26T17:09:38.759913885Z"}

# number of messages per project
NMESSAGES=${NMESSAGES:-10}
# size of each message - number of bytes to write to each line of the logger file, not
# the actual size of the JSON that is stored into ES
MSGSIZE=${MSGSIZE:-200}

ii=1
prefix=$( uuidgen )
if [ "$USE_JOURNAL" = "true" ] ; then
    formatter=format_journal
    if [ "${USE_CONTAINER_FOR_JOURNAL_FORMAT:-}" = true ] ; then
        sysfilter() {
            cat >> $datadir/journalinput.txt
        }
        postprocesssystemlog() {
            docker build -t viaq/journal-maker:latest journal-maker
            docker run --privileged -u 0 -e INPUTFILE=/var/log/journalinput.txt \
                -e OUTPUTFILE=/var/log/journal/messages.journal \
                -v $datadir:/var/log viaq/journal-maker:latest
            sudo chown -R ${USER}:${USER} $datadir/journal
        }
    else
        sysfilter() {
            /usr/lib/systemd/systemd-journal-remote - -o $systemlog
        }
        postprocesssystemlog() {
            :
        }
    fi
fi
if [ $USE_JOURNAL_FOR_SYSTEM = false ] ; then
    formatter=format_syslog_message
    sysfilter() {
        cat >> $systemlog
    }
    postprocesssystemlog() {
        :
    }
fi
$formatter $NMESSAGES $prefix $MSGSIZE $USE_JOURNAL_FOR_SYSTEM $USE_JOURNAL_FOR_CONTAINERS | sysfilter
postprocesssystemlog

if [ $USE_JOURNAL_FOR_CONTAINERS = false ] ; then
    jj=1
    while [ $jj -le $NPROJECTS ] ; do
        fn=$( format_json_filename $jj )
        format_json_file full $NMESSAGES $prefix $MSGSIZE > $datadir/containers/$fn
        format_json_file short $NMESSAGES $prefix $MSGSIZE >> $orig
        jj=$( expr $jj + 1 )
    done
fi

if [ "$USE_FLUENTD" = "true" ] ; then
    pushd ../docker-fluentd
    ./build-image.sh
    popd
    # copy fluentd config to config dir
    #    cp openshift-fluentd.conf $confdir/fluent.conf
    cp -r openshift-fluentd/* $confdir
    cp $fluentd_syslog_input $confdir/configs.d/dynamic/input-syslog-default-syslog.conf
    if [ $USE_JOURNAL_FOR_CONTAINERS = false ] ; then
        cp $fluentd_docker_input $confdir/configs.d/dynamic/input-docker-default-docker.conf
    fi
    rm -f $confdir/configs.d/openshift/input-post-forward-mux.conf \
        $confdir/configs.d/openshift/filter-pre-mux*.conf \
        $confdir/configs.d/openshift/filter-post-mux*.conf \
    # run fluentd with the config dir mounted as /etc/fluent
    STARTTIME=$(date +%s)
    collectorid=`docker run -p 24220:24220 -p 5141:5141/udp -v $datadir:/var/log -v $confdir:/etc/fluent --link viaq-elasticsearch -e ES_HOST=viaq-elasticsearch -e OPS_HOST=viaq-elasticsearch -e ES_PORT=9200 -e OPS_PORT=9200 -e JOURNAL_SOURCE=/var/log/journal -e USE_JOURNAL=$USE_JOURNAL -e JOURNAL_READ_FROM_HEAD=true -e SYSLOG_LISTEN_PORT=5141 -e DEBUG_FLUENTD=${DEBUG_FLUENTD} -e ES_SCHEME=http -e OPS_SCHEME=http -d viaq/fluentd:latest`
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
        docker run -p 5141:5141/udp $rsyslog_bindmount -v $datadir:/var/log --link viaq-elasticsearch -e ES_HOST=viaq-elasticsearch -e SYSLOG_LISTEN_PORT=5141 -it viaq/rsyslog-perf-test:latest gdb --args /usr/sbin/rsyslogd -n
    else
        collectorid=`docker run -p 5141:5141/udp $rsyslog_bindmount -v $datadir:/var/log --link viaq-elasticsearch -e ES_HOST=viaq-elasticsearch -e SYSLOG_LISTEN_PORT=5141 -d viaq/rsyslog-perf-test:latest`
    fi
fi

test_count_expected() {
    local curcount=`curl_es_ext $myhost "$myurl" -XPOST "$myqs" | get_count_from_json`
    echo count $curcount time $( date +%s )
    test "${curcount:-0}" -eq $NMESSAGES
}

max_wait_time=$( expr \( $NMESSAGES \* \( $NPROJECTS + 1 \) \) / 75 )
if [ $max_wait_time -lt 30 ] ; then
    max_wait_time=30
fi

echo waiting $max_wait_time for $NMESSAGES messages in .operations and $NPROJECTS projects in elasticsearch

qs='{"query":{"term":{"ident":"'"${prefix}"'"}}}'
myhost=localhost myurl="/.operations.*/_count" myqs="$qs" wait_until_cmd test_count_expected $max_wait_time 1 || {
    echo error: $NMESSAGES messages not found in .operations
    curl_es localhost .operations _search ident $prefix | python -mjson.tool
    curl_es_ext localhost /_cat/indices
    exit 1
}

iii=1
while [ $iii -le $NPROJECTS ] ; do
    myproject=`printf "%s${NPFMT}" $projprefix $iii`
    myhost=localhost myurl="/project.$myproject.*/_count" myqs="$qs" wait_until_cmd test_count_expected $max_wait_time 1 || {
        echo error: $NMESSAGES messages not found in $myproject
        curl_es localhost project.$myproject _search ident $prefix | python -mjson.tool
        exit 1
    }
    iii=`expr $iii + 1`
done

# now total number of records >= $startcount + $NMESSAGES
# mark time
MARKTIME=$(date +%s)

echo duration `expr $MARKTIME - $STARTTIME`

if [ "$SKIP_MESSAGES_TEST" = "true" ] ; then
    echo Skipping tests, code will terminate in 30 sec.
    sleep 30
    exit
fi

# search ES and extract the messages
#esmessages=`mktemp`
total=`expr $NMESSAGES \* \( $NPROJECTS + 1 \)`
curl_es localhost "" _search message $prefix "&fields=message&size=$total" | \
    python -c 'import json, sys; print "\n".join([ii["fields"]["message"][0] for ii in json.loads(sys.stdin.read())["hits"]["hits"]])' | \
    grep -v '^$' | \
    sort -n > $result

sort -n $orig > $orig.sorted

diff $orig.sorted $result
