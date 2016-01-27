import sys
import socket
import datetime
import json

appnames = {
    0: 'kernel',
    1: 'NetworkManager',
    2: 'docker',
    3: 'apache',
    4: 'ns-slapd',
    5: 'audit',
    6: 'sudo',
    7: 'CROND'
}

sock = None
if len(sys.argv) > 1:
    ip = sys.argv[1]
    port = int(sys.argv[2])
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)

nfacility = 24
#nfacility = 4
nsev = 8
#nsev = 4
version = 1
for facility in range(0, nfacility):
    for severity in range(0, nsev):
        pri = facility * 8 + severity
        ts = datetime.datetime.utcnow().isoformat() + "Z"
        hostname = 'host.example.test'
        msgid = 'msgid'
        hsh = {
            'pri'   : pri,
            'ver'   : version,
            'ts'    : ts,
            'hn'    : hostname,
            'app'   : appnames[pri % 8],
            'pid'   : pri * 13,
            'msgid' : msgid,
            'sd1'   : 'field1="value1"',
            'sd2'   : 'field2="value2"',
            'msg'   : 'This "is" a message [which] will \'require\' {JSON: escaping}'
        }
        hsh['cee'] = json.dumps({'msg': hsh['msg']})
        msg = '<%(pri)d>%(ver)d %(ts)s %(hn)s %(app)s %(pid)d %(msgid)s - %(msg)s' % hsh
        if sock:
            rv = sock.sendto(msg, (ip, port))
            print "rv %s" % rv
        else:
            print msg
        #        print '<%(pri)d>%(ver)d %(ts)s %(hn)s %(app)s %(pid)d %(msgid)s [SD1ID %(sd1)s][SD2ID %(sd2)s] @cee:%(cee)s' % hsh
