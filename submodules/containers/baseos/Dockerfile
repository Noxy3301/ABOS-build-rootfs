ARG arch=amd64
ARG version=3.20

FROM docker.io/${arch}/alpine:${version}

# update & prepare builder env
RUN apk update && apk upgrade && apk add alpine-sdk && rm -f /var/cache/apk/*
RUN adduser -D builder && adduser builder abuild

# setup atmark repos
# We do it after earlier update to have this work in case repo is missing
# as install does not require it (bootstrapping issue)
ARG at_version
RUN sed -i -e "1i@atmark http://download.atmark-techno.com/alpine/v${at_version}/atmark" \
	   -e "1ihttp://download.atmark-techno.com/alpine/v${at_version}/atmark" /etc/apk/repositories
# key-1
COPY atmark-601a0e69.rsa.pub /etc/apk/keys/
# key-2
COPY atmark-62b116af.rsa.pub /etc/apk/keys/
