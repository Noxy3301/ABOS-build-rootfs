ARG version=3.20

FROM alpine-${version}-x86_64

ARG pm_version=master

# setup postmarketos repo for cross build toolchains
# these could also be regenerated from alpine's aports scripts/bootstrap.sh
# but it's faster to download packages
RUN sed -i -e '$ahttp://postmarketos.brixit.nl/postmarketos/'"${pm_version}" \
	   /etc/apk/repositories
COPY build.postmarketos.org.rsa.pub /etc/apk/keys/

ARG packages="gcc-aarch64 g++-aarch64"

# filter out atmark-techno.com repo for bootstrap
RUN sed -e '/atmark-techno.com/d' /etc/apk/repositories > /tmp/repos \
 && apk upgrade --repositories-file /tmp/repos \
 && apk add --repositories-file /tmp/repos ${packages} distcc \
 && rm -f /var/cache/apk/* /tmp/repos

COPY cmdlist /cmdlist
ENV DISTCC_CMDLIST=/cmdlist
EXPOSE 3632/tcp
CMD ["/usr/bin/distccd", "--log-stderr", "--daemon", "--no-detach", "--allow=0.0.0.0/0"]
