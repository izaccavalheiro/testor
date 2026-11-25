# testor in a container

The image runs testor's orchestrator (dashboard, `/api/v1`, MCP) as an unprivileged user on a
read-only root file system. It reads and serves the testor home in the `/data` volume: runs
that `run.ps1` records into `/data/workspaces/.testor` (a runner that shares that folder, or a
future hub) and the files of `auth.json`.

```sh
docker compose up -d
# Add the first user: until one exists, the image answers loopback only (TESTOR_ANONYMOUS=loopback).
read -rs TESTOR_PASSWORD; export TESTOR_PASSWORD
docker compose exec -e TESTOR_PASSWORD testor /app/bin/testor eval 'Testor.Auth.CLI.user ~s[ada], ~s[admin]'
curl -u ada http://localhost:6767/api/v1/auth/me
```

| Variable | Why |
| -------- | --- |
| `TESTOR_ALLOWED_HOSTS` | every name browsers use (`testor.example.com`); IP addresses always work |
| `TESTOR_TRUSTED_PROXIES` | the address of a reverse proxy in front, so rate limiting and audit see clients |
| `TESTOR_VERSION` | the image tag (`0.3.0`); `latest` follows releases |

Limits of a container today: cancelling a run needs the run's process, which lives on the
runner, not in the container; device statistics describe the container's host as Linux sees
it from inside. Logs go to stdout (`docker compose logs testor`).

Verify an image before running it (the release workflow attests its provenance):

```sh
gh attestation verify oci://ghcr.io/izaccavalheiro/testor:<version> --repo izaccavalheiro/testor
```
