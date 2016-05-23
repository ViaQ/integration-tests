#!/usr/bin/env python
#
# ViaQ journal data generator - generate data in journalctl -o export format
# suitable for passing into /usr/lib/systemd/systemd-journal-remote
#
# Copyright 2018 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

import sys
import time
import socket

journal_system_defaults = {
    'boot_id': 'c5e8a3bb830440599bc35ff2305c62ae',
    'level': 3,
    'uid': 0,
    'gid': 0,
    'facility': 3,
    'ident': 'systemd',
    'transport': 'journal',
    'pid': 1,
    'comm': 'systemd',
    'exe': '/usr/lib/systemd/systemd',
    'cap_effective': '1fffffffff',
    'cgroup': '/',
    'code_file': 'src/core/unit.c',
    'code_line': 1417,
    'code_func': 'unit_status_log_starting_stopping_reloading',
    'machine_id': '4372f1e2f8c642d3a2f3ed11aa3fe654',
    'cmdline': '/usr/lib/systemd/systemd --switched-root --system --deserialize 20',
    'selinux_context': 'system_u:system_r:init_t:s0',
    'unit': 'network.service',
    'message_id': '7d4958e842da4a758f6c1cdc7b36dcc5'
}

container_defaults = {
    'boot_id': 'c5e8a3bb830440599bc35ff2305c62ae',
    'level': 3,
    'uid': 0,
    'gid': 0,
    'facility': 3,
    'ident': 'systemd',
    'transport': 'journal',
    'pid': 12345,
    'comm': 'dockerd-current',
    'exe': '/usr/bin/dockerd-current',
    'cap_effective': '1fffffffff',
    'systemd_slice': 'systemd.slice',
    'cgroup': '/system.slice/docker.service',
    'machine_id': '4372f1e2f8c642d3a2f3ed11aa3fe654',
    'cmdline': '/usr/bin/dockerd-current --add-runtime docker-runc=/usr/libexec/docker/docker-runc-current --default-runtime=docker-runc --authorization-plugin=rhel-push-plugin --exec-opt native.cgroupdriver=systemd --userland-proxy-path=/usr/libexec/docker/docker-proxy-current --selinux-enabled --log-driver journald --log-driver=journald --signature-verification=False --storage-driver devicemapper --storage-opt dm.fs=xfs --storage-opt dm.thinpooldev=/dev/mapper/docker-docker--pool --storage-opt dm.use_deferred_removal=true --storage-opt dm.use_deferred_deletion=true --storage-opt dm.libdm_log_level=3 --mtu=8951 --insecure-registry=172.30.0.0/16 --add-registry registry.access.redhat.com',
    'selinux_context': 'system_u:system_r:container_runtime_t:s0',
    'unit': 'docker.service',
}

counter = 0
# given a lot of inputs, return a string in journalctl -o export format, suitable for
# passing to /usr/lib/systemd/systemd-journal-remote
# too many parameters to enumerate as arguments . . .
def create_journal_record(**kwargs):
    global counter
    base_template = """__REALTIME_TIMESTAMP={rt_ts}
__MONOTONIC_TIMESTAMP={m_ts}
_BOOT_ID={boot_id}
PRIORITY={level}
_UID={uid}
_GID={gid}
_TRANSPORT={transport}
_PID={pid}
_COMM={comm}
_EXE={exe}
_CAP_EFFECTIVE={cap_effective}
_SYSTEMD_CGROUP={cgroup}
_MACHINE_ID={machine_id}
_CMDLINE={cmdline}
_SELINUX_CONTEXT={selinux_context}
_SYSTEMD_UNIT={unit}
MESSAGE={message}
_HOSTNAME={hostname}
_SOURCE_REALTIME_TIMESTAMP={src_rt_ts}
"""
    # set defaults
    if 'container_name' in kwargs:
        field_defaults = container_defaults
        extra_template = """CONTAINER_ID_FULL={container_id}
CONTAINER_NAME={container_name}
CONTAINER_ID={container_id_short}
CONTAINER_TAG={container_tag}
_SYSTEMD_SLICE={systemd_slice}
"""
    else:
        field_defaults = journal_system_defaults
        extra_template = """SYSLOG_FACILITY={facility}
SYSLOG_IDENTIFIER={ident}
CODE_FILE={code_file}
CODE_LINE={code_line}
CODE_FUNCTION={code_func}
MESSAGE_ID={message_id}
"""

    for kk,vv in field_defaults.items():
        kwargs[kk] = kwargs.get(kk, vv)
    kwargs['rt_ts'] = kwargs.get('rt_ts', int(time.time() * 1000000))
    kwargs['m_ts'] = kwargs.get('m_ts', counter)
    kwargs['src_rt_ts'] = kwargs.get('src_rt_ts', int(time.time() * 1000000))
    kwargs['hostname'] = kwargs.get('hostname', socket.gethostname())
    if 'container_id' in kwargs:
        kwargs['container_id_short'] = kwargs.get('container_id_short', kwargs['container_id'][0:12])
    return base_template.format(**kwargs) + extra_template.format(**kwargs)

# TODO: for container logs, we need to be able to hierarchically specify namespaces, pods, and containers e.g.
# - name: project1
#   id: optional-uuid e.g. for tracking with dummy data
#   pods:
#   - name: pod1
#     id: optional-uuid
#     containers:
#     - name: container1
#       id: container id
#     - name: container2
#     ...
#   - name: pod2
#   ....
# - name: project2
# ...
# for generating real data for doing real metadata lookups of real projects/pods
# for doing strictly load testing without a live k8s api, we just programatically generate dummy data
nprojects = 5
npods = 5
ncontainers = 1
# half system messages and half container messages
journal_system_numer = 1
journal_system_denom = 2
def journal_output_method(msg):
    global counter
    counter = counter + 1
    if (counter % journal_system_denom) < journal_system_numer:
        print create_journal_record(message=msg)
    else:
        projname = 'project{0:03d}-project-name'.format(counter % nprojects)
        podname = 'pod{0:03d}-pod-name'.format(counter % npods)
        contname = 'container{0:03d}-container-name'.format(counter % ncontainers)
        podid = '2d67916a-1eac-11e6-94ba-001c42e13{0:03d}'.format(counter % npods)
        contid = 'c2f056c02{0:03d}f26efd4e47c12ac95877644d2bee6537f279e9d3833ddf5e686e'.format(counter % ncontainers)
        container_name='k8s_{contname}.deadbeef_{podname}_{projname}_{podid}_abcdef01'.format(contname=contname,
            podname=podname, projname=projname,podid=podid)
        print create_journal_record(message=msg, container_name=container_name, container_id=contid, container_tag='container-tag')

if __name__ == '__main__':
    for msg in sys.stdin:
        journal_output_method(msg.strip())
