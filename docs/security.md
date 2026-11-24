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

## Cross-site requests

A state-changing request (`POST`, `DELETE`) is refused (`403`) when its `Origin` is not this
server (including the `null` origin of a sandboxed report), and when it carries none of a
Bearer token, the header `X-Testor: 1` or a JSON body. Cross-site forms cannot send the last
two without a CORS preflight, which testor never grants. Since browsers send Basic credentials
on their own, this is what stops another site from acting with them. The token endpoint needs
only the origin check: its answer cannot be read cross-site. MCP requests must be JSON, and a
foreign `Origin` is refused there too (DNS rebinding).

## Transport

testor speaks plain HTTP. Basic credentials and tokens are only as private as the network:

- over Tailscale, WireGuard encrypts the traffic end to end; the Windows firewall rule the
  installer adds lets in only the Tailscale range and the local subnet (`ALLOW_FROM`);
- on a network that is not yours, put a TLS-terminating proxy in front (Caddy, nginx,
  `tailscale serve`) and set `TESTOR_BIND=127.0.0.1` so testor listens locally only.

## Audit

Every state-changing request is logged to `testor.log` with who sent it, from where, and its
status (`audit: ada from 100.64.0.7: POST /api/v1/runs/<id>/cancel -> 200`); failed logins
with the user name and address.

## Other headers

`X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer` on every response; the
dashboard adds `X-Frame-Options: DENY` and `frame-ancestors 'none'`; API answers are
`Cache-Control: no-store`; every response has an `X-Request-Id`.

## What stays out of reach

Nothing in the API starts a command: commands reach the runner over SSH only. Maintenance
deletes only a fixed list of targets named by id (never a path from a request), is off until
`maintenance.enabled`, and needs the `maintain` scope. testor runs as the installing user (on
Windows with a limited token).
