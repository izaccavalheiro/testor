# syntax=docker/dockerfile:1
# testor's agent as an OCI image (linux/amd64 and linux/arm64): takes jobs from a testor and sends their runs
# to it ("upload": true). Build from the repository's root:
#
#   docker build -f runner/Dockerfile -t testor-agent .
#
# It holds PowerShell 7, git, run.ps1, agent.ps1, snapshot.ps1 and testor.ps1 (the client), runs as an unprivileged user (uid 10001)
# and suits a read-only root file system: the agent's home (runs before they are sent, cloned
# workspaces) is /home/agent, a volume. Give it agent.json at $TESTOR_AGENT_CONFIG
# (/etc/testor-agent/agent.json, with "home": "/home/agent/testor" and "upload": true) and its
# token in $TESTOR_AGENT_TOKEN. Projects' tools (Node.js, Python, ...) go in an image built FROM
# this one.
FROM debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0
# PowerShell's tarball for the platform being built, checked against the SHA-256 its release
# publishes (hashes.sha256).
# BuildKit sets TARGETARCH (a default here would replace it); without BuildKit it is empty: amd64.
ARG TARGETARCH
ARG PWSH_VERSION=7.6.9
ARG PWSH_SHA256_AMD64=1da6d6d6035d651f20e70ddee7c4c15ac6ab8b9fb40ee92240d91263f28a884b
ARG PWSH_SHA256_ARM64=02eb9991af447c7e7fe881acde195961afd397c40b8eb1c2b3856b84ec2d85f2
RUN case "${TARGETARCH}" in \
      amd64|"") arch=x64; sum="${PWSH_SHA256_AMD64}" ;; \
      arm64) arch=arm64; sum="${PWSH_SHA256_ARM64}" ;; \
      *) echo "no PowerShell for ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git libicu76 \
 && curl -fsSL -o /tmp/pwsh.tgz "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${arch}.tar.gz" \
 && echo "${sum}  /tmp/pwsh.tgz" | sha256sum -c - \
 && mkdir -p /opt/pwsh && tar -xzf /tmp/pwsh.tgz -C /opt/pwsh && chmod +x /opt/pwsh/pwsh \
 && ln -s /opt/pwsh/pwsh /usr/local/bin/pwsh && rm /tmp/pwsh.tgz \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --user-group --create-home --home-dir /home/agent --shell /usr/sbin/nologin agent
COPY runner/run.ps1 runner/agent.ps1 runner/snapshot.ps1 runner/testor.ps1 runner/detect.ps1 /opt/testor-agent/
USER 10001:10001
ENV HOME=/home/agent \
    TESTOR_AGENT_CONFIG=/etc/testor-agent/agent.json \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1
VOLUME ["/home/agent"]
# run.ps1 records next to itself: it goes into the agent's (writable) home at each start.
ENTRYPOINT ["pwsh", "-NoProfile", "-NonInteractive", "-Command", "$h = Join-Path $HOME 'testor'; $null = New-Item -ItemType Directory -Force $h; Copy-Item /opt/testor-agent/run.ps1 $h -Force; & /opt/testor-agent/agent.ps1 -Config $env:TESTOR_AGENT_CONFIG @args"]
