# The separate-account setup of docs/security.md, checked end to end: testor as the account
# `testor`, tests as `runner`. Built on the orchestrator's image (BASE) by the container
# workflow; run scenario.sh in it as root:
#
#   docker build -t testor:ci ../../orchestrator
#   docker build --build-arg BASE=testor:ci -f Dockerfile -t testor:two-accounts ../..
#   docker run --rm --user root --entrypoint bash testor:two-accounts /scenario.sh
ARG BASE=testor:ci
FROM ${BASE}
USER root
# PowerShell for run.ps1, checked against the hash its release notes publish.
RUN apt-get update && apt-get install -y --no-install-recommends acl libicu76 curl && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /tmp/pwsh.tgz https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/powershell-7.6.9-linux-x64.tar.gz \
 && echo "1da6d6d6035d651f20e70ddee7c4c15ac6ab8b9fb40ee92240d91263f28a884b  /tmp/pwsh.tgz" | sha256sum -c - \
 && mkdir -p /opt/pwsh && tar -xzf /tmp/pwsh.tgz -C /opt/pwsh && chmod +x /opt/pwsh/pwsh \
 && ln -s /opt/pwsh/pwsh /usr/local/bin/pwsh && rm /tmp/pwsh.tgz \
 && useradd -m -s /bin/bash runner \
 && mkdir -p /srv/testor/home /srv/testor/secrets /srv/workspaces \
 && for d in runs logs screenshots artifacts cancel attestations; do mkdir -p /srv/testor/home/$d; done \
 && chown -R testor:testor /srv/testor && chmod 700 /srv/testor/secrets && chmod 755 /srv/testor /srv/testor/home \
 && chown runner:runner /srv/workspaces
COPY runner/run.ps1 /srv/testor/home/run.ps1
COPY scripts/two-accounts/scenario.sh /scenario.sh
RUN chown testor:testor /srv/testor/home/run.ps1 && chmod 644 /srv/testor/home/run.ps1
ENV TESTOR_HOME=/srv/testor/home TESTOR_WORKSPACES=/srv/workspaces TESTOR_SECRETS_DIR=/srv/testor/secrets TESTOR_ANONYMOUS=loopback
