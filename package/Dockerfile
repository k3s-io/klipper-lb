FROM alpine:3.18
ARG BUILDDATE
LABEL buildDate=$BUILDDATE
RUN apk --no-cache upgrade && \
    apk add -U --no-cache iptables ip6tables nftables
COPY entry /usr/bin/
CMD ["entry"]
