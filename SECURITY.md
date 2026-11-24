# Security policy

## Reporting a vulnerability

Please report security problems privately, through GitHub's
[private vulnerability reporting](https://github.com/izaccavalheiro/testor/security/advisories/new)
(the repository's **Security** tab, **Report a vulnerability**). Do not open a public issue.

Include the version (`GET /api/health`), the runner's OS, whether authentication was on, and
steps to reproduce. You will get an answer within a week. Once a fix is released, the advisory
is published with credit to you, unless you prefer otherwise.

## Supported versions

| Version | Security fixes |
| ------- | -------------- |
| the latest minor release | yes |
| the minor release before it | for three months after its successor is released |
| older | no: upgrade |

## Scope

testor's threat model and protections are described in
[docs/security.md](docs/security.md). In scope, for example:

- reaching data or actions without the scope they need, or with authentication on and no
  credentials;
- forging or extending tokens or signed links;
- cross-site requests that act with a user's credentials;
- a report or artifact that escapes its sandbox to use the API;
- deleting anything outside the maintenance targets;
- `run.ps1` changing a command's output, stderr or exit code.

Out of scope: plain HTTP on a network you do not control (testor documents that it must run
over Tailscale or behind a TLS proxy there), the commands your own tasks run, and an attacker who
already has SSH access to the runner as its user.
