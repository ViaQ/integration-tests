FROM fedora:23

MAINTAINER The ViaQ Community <community@TBA>

ENV INPUTFILE=/var/log/journalinput.txt \
    OUTPUTFILE=/var/log/journal/messages.journal

RUN dnf -y install /usr/lib/systemd/systemd-journal-remote

CMD /usr/lib/systemd/systemd-journal-remote -o ${OUTPUTFILE} ${INPUTFILE}
