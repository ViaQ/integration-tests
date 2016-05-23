FROM viaq/rsyslog-collector:latest
MAINTAINER The ViaQ Community <community@TBA>
# for doing rsyslog performance tests
ADD rsyslog.conf /etc/rsyslog.conf
ADD *.rulebase syslog-input-filter.conf /etc/rsyslog.d/
#ENV DEBUG=true RSYSLOG_DEBUG="Debug"
RUN yum -y install gdb rsyslog-debuginfo

CMD /usr/sbin/run.sh
