# syntax=docker/dockerfile:1
# testor's orchestrator as an OCI image (Linux, amd64 and arm64): the dashboard, the API and
# MCP over a testor home kept in the /data volume. Build from orchestrator/:
#
#   docker build -t testor orchestrator
#
# The image runs as an unprivileged user (uid 10001) on a read-only root file system, logs to
# stdout, and while no user exists answers only loopback (TESTOR_ANONYMOUS=loopback): add one
# before exposing it (examples/compose/README.md). Base images are pinned by digest; Dependabot
# proposes updates.

FROM elixir:1.20.5-otp-29-slim@sha256:8c1b56cfb8b3cacee2662e29dc650a8d7f7755972ef79c9277fc3f50c5411fd7 AS build
ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /src
# The slim image has no CA certificates: Hex is fetched over TLS.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mix local.hex --force && mix local.rebar --force
# Dependencies first, so source changes do not download and compile them again.
COPY mix.exs mix.lock ./
COPY config/config.exs config/
RUN mix deps.get --only prod && mix deps.compile
COPY config config
COPY lib lib
COPY priv priv
COPY rel rel
RUN mix release --overwrite --path /out

FROM debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0
# The release brings its own Erlang runtime; it needs OpenSSL (crypto), the C++ runtime and
# ncurses, and procps for the process queries (ps).
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3t64 libstdc++6 libncurses6 libsctp1 procps ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --user-group --home-dir /data --shell /usr/sbin/nologin testor \
 && mkdir -p /data/workspaces/.testor \
 && chown -R 10001:10001 /data
COPY --from=build /out /app
USER 10001:10001
ENV LANG=C.UTF-8 \
    HOME=/data \
    TESTOR_WORKSPACES=/data/workspaces \
    TESTOR_HOME=/data/workspaces/.testor \
    TESTOR_PORT=6767 \
    TESTOR_LOG=stdout \
    TESTOR_ANONYMOUS=loopback \
    RELEASE_TMP=/tmp
EXPOSE 6767
VOLUME ["/data"]
ENTRYPOINT ["/app/bin/testor"]
CMD ["start"]
