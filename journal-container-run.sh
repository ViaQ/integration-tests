#!/bin/sh

set -euo pipefail

sjr=/usr/lib/systemd/systemd-journal-remote
yum install -y $sjr > /dev/null
cat $INPUTFILE | $sjr - -o $OUTPUTFILE
chmod 777 `dirname $OUTPUTFILE`
chmod 644 $OUTPUTFILE
journalctl --file $OUTPUTFILE -n 1
