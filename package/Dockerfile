FROM alpine:3.16
ARG BUILDDATE
LABEL buildDate=$BUILDDATE
RUN apk --no-cache upgrade && \
    apk add -U --no-cache iptables ip6tables
COPY entry /usr/bin/
CMD ["entry"]
