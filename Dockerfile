FROM alpine:3.22 AS builder

RUN apk add --no-cache build-base git linux-headers

WORKDIR /src
COPY . .
RUN make distclean \
    && make -j"$(getconf _NPROCESSORS_ONLN)" \
    && strip src/redis-cluster-proxy

FROM alpine:3.22

LABEL org.opencontainers.image.title="redis-cluster-proxy" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.source="https://github.com/jlzan1314/redis-cluster-proxy"

RUN apk add --no-cache redis \
    && addgroup -S app \
    && adduser -S -G app app

COPY --from=builder /src/src/redis-cluster-proxy /usr/local/bin/redis-cluster-proxy

USER app
WORKDIR /home/app
EXPOSE 7777

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD redis-cli -h 127.0.0.1 -p 7777 PING | grep -qx PONG

ENTRYPOINT ["/usr/local/bin/redis-cluster-proxy"]
