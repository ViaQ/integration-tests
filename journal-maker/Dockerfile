FROM centos:7

MAINTAINER The ViaQ Community <community@TBA>

ENV INPUTFILE=/var/log/journalinput.txt \
    OUTPUTFILE=/var/log/journal/messages.journal

RUN rpmkeys --import file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7 && \
    yum -y install /usr/lib/systemd/systemd-journal-remote

CMD /usr/lib/systemd/systemd-journal-remote -o ${OUTPUTFILE} ${INPUTFILE}
