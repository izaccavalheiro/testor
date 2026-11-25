# Security

testor serves test output, screenshots and artifacts, and can cancel and delete runs and
clean the runner's disk. This page describes who can do what, and how to set it up.

## Authentication

Authentication is **off until you add a user**, so an existing install keeps working. Once
`<home>/auth.json` lists a user, every request needs credentials except the health checks
(`GET /api/health`, `GET /api/v1/health`), the OpenAPI document and signed file links.

| Scheme | For | How |
| ------ | --- | --- |
| HTTP Basic (RFC 7617) | the dashboard, `curl -u` | browsers ask for the user name and password once and send them with every request, the event streams included |
| Bearer JWT (RFC 6750, RFC 7519) | scripts, CI, MCP clients | `POST /api/v1/auth/token` with Basic credentials, or `task testor:token` |

Add users from the workstation (the password travels on the SSH session's stdin, never on a
command line):

```sh
read -rs TESTOR_PASSWORD; export TESTOR_PASSWORD   # 12 characters or more
task testor:user USER=ada ROLE=admin
task testor:user USER=ci ROLE=operator
task testor:token USER=ci DAYS=30 SCOPE="read operate"   # prints a token
```

On the runner itself, the release has the same commands (`bin\testor.bat` on Windows; the
expression needs neither parentheses nor double quotes, which cmd.exe would mangle):

```sh
TESTOR_PASSWORD=... bin/testor eval 'Testor.Auth.CLI.user ~s[ada], ~s[admin]'
bin/testor eval 'Testor.Auth.CLI.list'
bin/testor eval 'Testor.Auth.CLI.token ~s[ada], 7, ~s[read]'
bin/testor eval 'Testor.Auth.CLI.revoke ~s[ada]'     # her tokens issued until now stop working
bin/testor eval 'Testor.Auth.CLI.remove ~s[ada]'
bin/testor eval 'Testor.Auth.CLI.rotate_key'          # every token and signed link stops working
bin/testor eval 'Testor.Auth.CLI.enable false'        # off again, users kept
```

A running testor reads `auth.json` and the key again within a second: no restart.

### Roles and scopes

| Role | Scopes | Can |
| ---- | ------ | --- |
| `viewer` | `read` | read runs, logs, specs, screenshots, artifacts, device stats, maintenance scans |
| `operator` | `read operate` | also cancel and delete runs, run the janitor, start a maintenance scan |
| `admin` | `read operate maintain` | also delete maintenance targets |

A token carries a subset of its user's scopes (`scope` when it is requested) and is checked
against the user on every request: removing a user, lowering a role or revoking takes effect
at once. Only Basic credentials can obtain a token, so a token cannot renew itself.

### Tokens

HS256 JSON Web Tokens with `iss` and `aud` `testor`, `sub` (the user), `iat`, `nbf`, `exp`,
`jti` and `scope`. Only `HS256` is accepted (a token naming `none` or any other algorithm is
refused before its signature is checked), signatures are compared in constant time, and 30
seconds of clock skew are allowed. Lifetimes: 60 minutes by default, 30 days at most
(`tokens.defaultTtlMinutes`, `tokens.maxTtlDays` in `auth.json`; `expires_in` in the request).

The signing key is `<home>/jwt.key` (32 random bytes, created on first use, readable by its
owner only), or `TESTOR_JWT_SECRET` (32 bytes or more) when set.

### Passwords

PBKDF2-HMAC-SHA256 with a random 16-byte salt and 600,000 iterations (OWASP's recommendation),
from OTP's `:crypto`, so the release needs no native dependency on any OS. The hash names its
iteration count, which can be raised later. An unknown user costs the same time as a wrong
password. A verified pair is remembered for 5 minutes under an HMAC keyed with a secret drawn
at start (the dashboard sends its credentials with every request); changing the password
forgets it at once.

### Brute force

After 10 failed attempts (wrong password, unknown user, forged token) in 15 minutes, a client
address is answered `429` with `Retry-After` until the window ends. Expired tokens do not count.

### `auth.json`

```json
{
  "users": {
    "ada": { "password": "$pbkdf2-sha256$600000$<salt>$<hash>", "role": "admin" },
    "ci":  { "password": "$pbkdf2-sha256$600000$<salt>$<hash>", "role": "operator", "tokensValidAfter": 1795000000 }
  },
  "tokens": { "defaultTtlMinutes": 60, "maxTtlDays": 30 },
  "enabled": true
}
```

The CLI writes it (replacing it in one rename, mode 0600). A file that cannot be read or
parsed, or a key that is not valid, **locks everything but the health checks** until it is
fixed (fail closed), and says why in `testor.log`.

## Screenshots and artifacts: signed links

While authentication is on, screenshot and artifact URLs in every answer carry a signature:
`/s/<expiry>.<hmac>/shots/<run>/...`, valid one to two days and only for that run's files.
Images, videos and HTML reports load without credentials. A report runs sandboxed
(`Content-Security-Policy: sandbox`) with an opaque origin, so it sends no credentials, but
its relative links stay under its own signed prefix. The plain `/shots/` and `/artifacts/`
routes need credentials. Links are sent with `Referrer-Policy: no-referrer`.

## Network exposure

**While authentication is off**, testor answers only clients at private addresses: loopback,
RFC 1918 (`10/8`, `172.16/12`, `192.168/16`), link-local, CGNAT (`100.64/10`, Tailscale's
range) and IPv6 unique-local; any other address gets `403` (the health checks stay public).
`TESTOR_ANONYMOUS` changes it: `loopback`, or `any` (every address, as before 0.3: only on a
network you trust). Adding a user is the better fix.

**DNS rebinding.** A page on another site can make the browser resolve its own name to this
server and then read it as same-origin; the `Origin` check cannot tell, because origin and
host are both the attacker's name. testor answers only requests whose `Host` is an IP address
(a rebinding needs a name), `localhost`, this machine's name (also as `<name>.local`), or a
name in `TESTOR_ALLOWED_HOSTS`; anything else gets `421`.

```sh
TESTOR_ALLOWED_HOSTS="testor.example.com, runner.tail1234.ts.net"   # exact names
TESTOR_ALLOWED_HOSTS=".example.com"                                  # every subdomain
TESTOR_ALLOWED_HOSTS="*"                                             # no check
```

**Behind a reverse proxy**, list it in `TESTOR_TRUSTED_PROXIES` (addresses or CIDR ranges):
testor then takes the client's address from `X-Forwarded-For` (read from the right, skipping
trusted proxies) for rate limiting, the audit log and the check above. Without it, every
client has the proxy's address, which for a local proxy is loopback: a proxy on the same
machine with authentication off is open to whoever reaches the proxy.

Set these for the service with `task testor:deploy`, which the runner keeps between deploys:

```sh
task testor:deploy ALLOWED_HOSTS=testor.example.com TRUSTED_PROXIES=127.0.0.1 BIND=127.0.0.1
```

## Cross-site requests

A state-changing request (`POST`, `DELETE`) is refused (`403`) when its `Origin` is not this
server (including the `null` origin of a sandboxed report), and when it carries none of a
Bearer token, the header `X-Testor: 1` or a JSON body. Cross-site forms cannot send the last
two without a CORS preflight, which testor never grants. Since browsers send Basic credentials
on their own, this is what stops another site from acting with them. The token endpoint needs
only the origin check: its answer cannot be read cross-site. MCP requests must be JSON, and a
foreign `Origin` is refused there too; DNS rebinding is stopped by the `Host` allow-list
([network exposure](#network-exposure)).

## Files runs leave

Runs write the screenshots, artifacts, logs and records testor serves. A symbolic link or a
junction among them is never followed: the file routes refuse a path with a link in it, the
directory walks skip links (a loop cannot make them endless), and records and logs must be
regular files. `run.ps1` does not copy links into a run's screenshots or artifacts.

Cancelling kills the process a run's record names, and a run could rewrite its record. testor
checks the process first and kills nothing when it is testor itself or a process above it
(which would stop the service), when it has ended, or when it started after the run (its id
was reused); the run is cancelled with a warning.

## Limits

| What | Limit | Beyond it |
| ---- | ----- | --------- |
| failed sign-ins per client address | 10 in 15 minutes | `429` until the window ends |
| failed passwords per user, from any address | 30 in 15 minutes | `429` for passwords not yet verified; a browser that signed in keeps working |
| password hashes at once | twice the CPU's schedulers | `503`, `Retry-After: 1` |
| event streams | 256, and 16 per user (or per address without authentication) | `503`, `Retry-After: 10` |
| a log read | 8 MB from the end | cut to the limit |
| a request body | 64 KB (1 MB for MCP) | `413` |


## Transport

testor speaks plain HTTP unless it is given a certificate. Basic credentials and tokens are
only as private as the network:

- over Tailscale, WireGuard encrypts the traffic end to end; the Windows firewall rule the
  installer adds lets in only the Tailscale range and the local subnet (`ALLOW_FROM`);
- with `TESTOR_TLS_CERT` and `TESTOR_TLS_KEY` (PEM files: the certificate with its chain, and
  its key) testor speaks HTTPS only, TLS 1.2 and 1.3 with strong ciphers, and sends
  `Strict-Transport-Security`; `tailscale cert` or any ACME client provides the files
  (`task testor:deploy TLS_CERT=... TLS_KEY=...`);
- or put a TLS-terminating proxy in front (Caddy, nginx, `tailscale serve`) and set
  `TESTOR_BIND=127.0.0.1` so testor listens locally only.

## Audit

Every state-changing request and every failed sign-in is an entry of `<home>/audit.jsonl`:
who, how (`basic`, `bearer`), from where, the method, path, status and request id. Each entry
holds the SHA-256 of the one before (`prev`) and an Ed25519 signature with the attestation key
(`sig`, over the entry without it), so an edited, removed or reordered entry breaks the chain
at that line. `GET /api/v1/audit` (scope `maintain`) gives the last entries and whether the
whole file verifies; anyone with the public key (`GET /api/v1/attestation/key`) can check a copy
(`Testor.Audit.verify/3`). Over 16 MB the file is renamed `audit-<time>.jsonl` and the chain
continues in a new one. Ship it to a SIEM as JSON lines. `testor.log` keeps a line per request
too.

## Secrets in logs

`run.ps1` writes `***` in the stored log, and in the record's `error`, in place of the values
of environment variables whose names look secret (`TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`,
`API_KEY`, `PRIVATE_KEY`, `CREDENTIAL`) or are listed in `TESTOR_MASK` (comma-separated names),
when 6 characters or longer. The terminal that started the run still sees the output
unchanged. A secret a test prints after transforming it (base64, split) is not recognised:
masking is a safety net, not a reason to print secrets.

## AI agents (MCP)

Run output, commands, errors and test names come from the code under test, which can write
text meant to steer an agent (prompt injection). `get_run_log` returns the output fenced in
`<untrusted-output run="<id>">` after a line saying to treat it as data, with any such fence
inside the output defused, and the server's instructions say the same of every field. Give
agents a token with the `read` scope unless they must cancel or delete runs.

## Other headers

`X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer` on every response; the
dashboard adds `X-Frame-Options: DENY` and `frame-ancestors 'none'`; API answers are
`Cache-Control: no-store`; every response has an `X-Request-Id`.

## Run attestations

Every finished run is signed (Ed25519, an in-toto statement in a DSSE envelope) with
`signing.key` in the secrets folder: `GET /api/v1/runs/<id>/attestation`, verified with the key
from `GET /api/v1/attestation/key`. See [attestation.md](attestation.md).

## Who started a run

`run.ps1` records an `actor` with each run: the account (`user`) and SSH client address
(`client`) the runner sees, and who the workstation says it is (`declared`, from
`TESTOR_ACTOR`, which `remote.yml` sets to `<user>@<workstation>` or `ACTOR`). The first two are
what the runner observed; the third is informative only.

## Secrets

`auth.json`, `jwt.key` and `signing.key` live in the data folder unless `TESTOR_SECRETS_DIR`
names another.
Test commands run as the same account as testor (see below), so they can read either file
wherever it is: moving them protects them only once the tests run as an account that cannot
read that folder.

## Running tests in a separate account

By default testor and the tests run as the same account, so a test (or a dependency it
installs) can read `jwt.key`, add itself to `auth.json` or change `run.ps1`. To make that
impossible, run the service as one account and the tests (the SSH login) as another:

| | service account (`testor`) | test account (the SSH login) |
| --- | --- | --- |
| secrets folder (`TESTOR_SECRETS_DIR`) | owns it, mode 0700 | no access |
| the release, `run.ps1`, the testor home folder | owns them | read only |
| `runs`, `logs`, `screenshots`, `artifacts`, `cancel` | read, write, delete | write (default ACL keeps what it writes the service's too) |
| `attestations` | owns it | read only |

The testor home must not be inside the test account's home folder (it could rename it and put
its own in place). Cancelling works across the two accounts: testor writes `cancel/<id>`, and
`run.ps1`, in the test account's session, ends its own process tree.

On Linux (as root; verified in a container):

```sh
useradd --system --home-dir /srv/testor --shell /usr/sbin/nologin testor
mkdir -p /srv/testor/home /srv/testor/secrets
for d in runs logs screenshots artifacts cancel attestations; do mkdir -p /srv/testor/home/$d; done
chown -R testor:testor /srv/testor && chmod 700 /srv/testor/secrets && chmod 755 /srv/testor/home
for d in runs logs screenshots artifacts cancel; do
  setfacl -m u:ci:rwx,u:testor:rwx /srv/testor/home/$d      # ci: the test account
  setfacl -d -m u:ci:rwx,u:testor:rwx /srv/testor/home/$d
done
# the service (a system unit, User=testor) with:
#   TESTOR_HOME=/srv/testor/home TESTOR_SECRETS_DIR=/srv/testor/secrets
#   TESTOR_WORKSPACES=/home/ci/test-run
```

and in the projects' Taskfiles `HOME_DIR: /srv/testor/home` (an absolute path).

On Windows the same split is a local account for the service (the scheduled task's
principal) and a standard, non-administrator account for SSH: an administrator can read any
file. Give the test account Modify on the five data folders (`icacls <dir> /grant ci:(OI)(CI)M`)
and nothing on the secrets folder. This has not been verified end to end yet.

What still needs one account, and so stops working when they differ: measuring and cleaning
the test account's caches and snapshots (maintenance), and listing PowerShell sessions that
`run.ps1` did not start.

## What stays out of reach

Nothing in the API starts a command: commands reach the runner over SSH only. Maintenance
deletes only a fixed list of targets named by id (never a path from a request), is off until
`maintenance.enabled`, and needs the `maintain` scope. testor runs as the installing user (on
Windows with a limited token), unless it is set up in an account of its own
([above](#running-tests-in-a-separate-account)).
