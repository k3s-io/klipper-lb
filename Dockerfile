FROM alpine:3.23
ARG BUILDDATE
LABEL buildDate=$BUILDDATE
RUN apk --no-cache upgrade && \
    apk add -U --no-cache iptables ip6tables nftables iptables-legacy && \
    apk del libcrypto3 libssl3 apk-tools zlib
COPY entry /usr/bin/
CMD ["entry"]
