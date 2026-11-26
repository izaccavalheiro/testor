# Security

testor serves test output, screenshots and artifacts, and can cancel and delete runs and
clean the runner's disk. This page describes who can do what, and how to set it up.

## Authentication

Authentication is **off until you add a user** (or an identity provider), so an existing
install keeps working. Once `<home>/auth.json` lists one, every request needs credentials
except the health checks (`GET /api/health`, `GET /api/v1/health`), the OpenAPI document, the
token keys (`/.well-known/jwks.json`), the sign-in pages and signed file links.

| Scheme | For | How |
| ------ | --- | --- |
| HTTP Basic (RFC 7617) | the dashboard, `curl -u` | browsers ask for the user name and password once and send them with every request, the event streams included |
| Bearer JWT (RFC 6750, RFC 7519) | scripts, CI, MCP clients | `POST /api/v1/auth/token` with Basic credentials, or `task testor:token` |
| OpenID Connect | people, through the dashboard | sign in with the company's identity provider ([below](#single-sign-on-openid-connect)) |

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
bin/testor eval 'Testor.Auth.CLI.roll_token_key'      # a new token key; tokens of the old one live out their time
bin/testor eval 'Testor.Auth.CLI.rotate_key'          # every token and signed link stops working
bin/testor eval 'Testor.Auth.CLI.enable false'        # off again, users kept
```

A running testor reads `auth.json` and the key again within a second: no restart.

### Roles and scopes

| Role | Scopes | Can |
| ---- | ------ | --- |
| `viewer` | `read` | read runs, logs, specs, screenshots, artifacts, device stats, maintenance scans |
| `operator` | `read operate` | also cancel and delete runs, run the janitor, start a maintenance scan |
| `admin` | `read operate maintain execute` | also delete maintenance targets, and queue and cancel jobs |
| `exec-admin` | `read operate maintain execute exec` | also send commands to agents that accept them ([exec mode](handoff.md#exec-mode)); given by choice only |
| `agent` | `agent` | only take jobs and report on them (`runner/agent.ps1`) |

A token carries a subset of its user's scopes (`scope` when it is requested) and is checked
against the user on every request: removing a user, lowering a role or revoking takes effect
at once. Only Basic credentials can obtain a token, so a token cannot renew itself.

### Projects

A user can be limited to some projects, so teams share one testor without seeing each other's
work: `"projects": ["web", "lib-*"]` in `auth.json` (`*` matches anything), or
`task testor:projects USER=ci PROJECTS="web lib-*"` (`PROJECTS=all` lifts it). Without the
list, a user sees every project, as before. Their tokens follow the user at once.

- A run, job or project of another project, named in a path (`/api/v1/runs/<id>/...`, logs,
  files, `/events/runs/<id>`, attestations, cancel and delete), answers `404`, as if it did
  not exist.
- Lists leave the others out before paging: runs, projects, jobs, the galleries, the
  dashboard's state, MCP's tools; live event streams drop their events.
- What spans every project needs access to every project (`403` otherwise): maintenance,
  cleanup, the audit trail, `/metrics`, PowerShell sessions, the agents' keys.
- Jobs are queued only for one's projects; an agent user limited to projects only takes their
  jobs.
- A list that cannot be read (not a list, or names that are not names) fails closed: the user
  sees no project, and `testor.log` says why.

A user can also hold **a role per project**: `"projects": {"web*": "operator", "docs":
"viewer"}` (or `task testor:projects USER=ana PROJECTS="web*=operator docs=viewer"`).

- What a request does to a project it names (cancelling or deleting a run, queuing or
  cancelling a job, taking one as an agent, MCP's tools) needs a scope a role of that project
  grants: `403` otherwise. The user's `role` is then not used.
- Lists, streams and MCP show the runs of projects one of their roles may read (an `agent`
  role reads nothing); the others answer `404`, as above.
- A token carries the scopes asked for, and a project's roles limit them further.
- An entry with a pattern or a role testor does not know is left out (fail closed), and
  `testor.log` says so. `/api/v1/auth/me` shows `projectRoles`.

### Tokens

JSON Web Tokens with `iss` and `aud` `testor`, `sub` (the user), `iat`, `nbf`, `exp`, `jti`
and `scope`, signed with Ed25519 (`EdDSA`, RFC 8037). The header's `kid` names the key: its
JWK thumbprint (RFC 7638). 30 seconds of clock skew are allowed. Lifetimes: 60 minutes by
default, 30 days at most (`tokens.defaultTtlMinutes`, `tokens.maxTtlDays` in `auth.json`;
`expires_in` in the request).

The public keys are at `GET /.well-known/jwks.json` (a JSON Web Key Set, no credentials
needed, cacheable for 5 minutes), so a gateway, a hub or any other service verifies a testor
token without a secret that could also mint one. A verifier must also check `iss`, `aud` and
`exp`; whether the user still exists and still has the scope only testor knows
(`/api/v1/auth/me` answers it).

The private keys are `<home>/token-keys.json` (created on first use, readable by its owner
only), or `TESTOR_TOKEN_KEY` (a base64 Ed25519 seed of 32 bytes) for replicas that share one
key from a secret store. `roll_token_key` puts a new key first: the previous ones stay in the
set and verify the tokens they signed before, until those expire, then are dropped; a token a
retired key signed afterwards is refused. Roll on a schedule, and well after verifiers that
cache the set have fetched it. `rotate_key` replaces every key at once, for a key that leaked.

Each algorithm is checked with its own kind of key only, and a token naming any other (`none`,
`RS256`, ...) is refused before its signature is looked at.

**HS256**: tokens issued before 0.8 are HMAC-SHA256, keyed with `<home>/jwt.key` (32 random
bytes) or `TESTOR_JWT_SECRET` (32 bytes or more). They are accepted until the next major
version, `"tokens": {"acceptHs256": false}` refuses them at once, and
`"tokens": {"algorithm": "HS256"}` keeps issuing them. The HMAC is compared in constant time.
The same key signs screenshot and artifact links.

### Single sign-on (OpenID Connect)

People sign in to the dashboard with the identity provider they already use (Entra ID,
Google, Okta, Keycloak, Authentik, Dex, GitLab, ...), and their groups decide their role and
projects. Register testor with the provider as a web application whose redirect URI is
`https://<testor>/auth/callback`, then add to `auth.json`:

```json
"oidc": {
  "issuer": "https://login.example.com/realms/eng",
  "clientId": "testor",
  "clientSecret": "...",
  "redirectUri": "https://testor.example.com/auth/callback",
  "roles": { "admin": ["platform"], "operator": ["qa"], "viewer": ["*"] },
  "projects": { "web-team": ["web", "web-*"], "platform": ["*"] }
}
```

| Key | Meaning |
| --- | ------- |
| `issuer` | the provider's issuer URL: `https` (`http` on loopback only); its discovery document must name the same issuer |
| `clientId`, `clientSecret` | the client testor is; the secret can come from `TESTOR_OIDC_CLIENT_SECRET` instead, and without one testor is a public client (PKCE only) |
| `redirectUri` | testor's `/auth/callback` as the provider knows it; `https` makes the cookies `Secure` |
| `roles` | the groups of each role (`admin`, `operator`, `viewer`); `*` is anyone the provider signs in. The highest that matches wins; someone in none is refused |
| `projects` | the projects of each group (`*` as a group: everyone; `*` as a project: all). A user sees their groups' union; someone in no listed group sees none. Without `projects`, every project |
| `usernameClaim`, `groupsClaim` | the claims with the user's name (`email`, which must not be unverified) and groups (`groups`) |
| `scopes` | more scopes to ask for (`openid email profile` always): `groups` for providers that need it |
| `sessionHours` | how long a session lasts: 8 hours by default, a week at most |
| `sessionsValidAfter` | a Unix time: every session started before it ends |

How it holds:

- The authorization code flow with PKCE (`S256`), `state` and `nonce`. They travel in an
  encrypted cookie that lives ten minutes (`HttpOnly`, `SameSite=Lax`, path `/auth`), so any
  replica can finish a sign-in, and a callback of a sign-in another browser started fails.
- The ID token is checked like any token testor trusts: signed (RS256, ES256 or EdDSA) with a
  key of the provider's JWKS, which is fetched again when an unknown key appears (at most once
  a minute); issued by the issuer for this client (`azp` when there are several audiences);
  unexpired; with the login's nonce. Discovery and keys are kept an hour.
- A session is a token signed with testor's token keys for the audience `testor-session`, in a
  cookie (`HttpOnly`, `SameSite=Lax`, `Secure` with an `https` redirect URI). It is not a
  Bearer token, and a Bearer token is not a session. It carries the role and projects of the
  sign-in: a change of groups applies at the next sign-in, and `sessionsValidAfter` ends the
  sessions at once.
- A visitor without credentials is sent to the provider; API requests get `401`. Only
  `/?basic` asks the browser for a password: users of `auth.json` keep working, for scripts
  and as a break-glass account when the provider is down.
- A refused sign-in is logged, audited and counts as a failed attempt of the address (see
  [brute force](#brute-force)); a sign-in is audited with the role it got.
- The dashboard shows who is signed in and signs out (`POST /auth/logout`).

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
    "ci":  { "password": "$pbkdf2-sha256$600000$<salt>$<hash>", "role": "operator", "tokensValidAfter": 1795000000,
             "projects": ["web", "lib-*"] }
  },
  "tokens": { "defaultTtlMinutes": 60, "maxTtlDays": 30, "algorithm": "EdDSA", "acceptHs256": true },
  "oidc": { "issuer": "https://login.example.com", "clientId": "testor", "redirectUri": "https://testor.example.com/auth/callback",
            "roles": { "viewer": ["*"] } },
  "enabled": true
}
```

The CLI writes it (replacing it in one rename, mode 0600). A file that cannot be read or
parsed, or a key that is not valid, **locks everything but the health checks** until it is
fixed (fail closed), and says why in `testor.log`.

## Screenshots and artifacts: signed links

While authentication is on, screenshot and artifact URLs in every answer carry a signature:
`/s/v2.<expiry>.<viewer>.<hmac>/shots/<run>/...`, valid for that run's files only, for
`linkMinutes` (auth.json, 15 by default), and for the person it was made for:

- `<viewer>` is an HMAC of the user's name, never the name. A request that carries
  credentials (Basic, a token, a session) must be that user and may see the run's project, or
  it gets `403`; a request without any (an image in a sandboxed report) needs the link alone.
  A copied link stops working within minutes and never opens for another signed-in person.
- Answers carry each link bound for whoever asked (JSON, event streams, MCP), and the
  dashboard fetches the links it shows again before they expire. A video that is playing or a
  download already started keeps going.
- A link for anyone (`<viewer>` `-`) is made only for a request without a user, and the audit
  trail records it (`link`).
- Links of version 1 (`/s/<expiry>.<hmac>/`, one to two days, before 0.13) open until they
  expire; testor makes none. Rotating the key (`Testor.Auth.CLI.rotate_key`) ends every link.

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
and session cookies on their own, this is what stops another site from acting with them (the
session cookie is also `SameSite=Lax`). The token endpoint needs
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
- or testor orders its certificates itself from an ACME CA (Let's Encrypt by default), with
  `tls.acme` in config.json (below);
- or put a TLS-terminating proxy in front (Caddy, nginx, `tailscale serve`) and set
  `TESTOR_BIND=127.0.0.1` so testor listens locally only.

### Certificates from ACME

```json
{"tls": {"acme": {"domains": ["testor.example.com"], "email": "ops@example.com", "httpPort": 80}}}
```

testor registers an account with the CA (accepting its terms of service), orders a
certificate for `domains` over HTTP-01, checks it (its names, its key, its chain to the
system's CAs or `caBundle`) and serves it at once; it renews at two thirds of the lifetime, or
in the window the CA suggests (ACME Renewal Information), without a restart. The settings:

| Key | Default | |
| --- | ------- | - |
| `directory` | Let's Encrypt production | the CA's directory, HTTPS only; try `https://acme-staging-v02.api.letsencrypt.org/directory` first |
| `domains` | (required) | names in `TESTOR_ALLOWED_HOSTS` |
| `email` | none | the account's contact |
| `httpPort` | none | a plain-HTTP listener for the challenges (80 for a public CA), which redirects everything else to HTTPS |
| `caBundle` | none | a PEM file of CAs to trust as well (a private CA) |
| `renewBefore` | two thirds | days before expiry to renew at the latest |
| `keyType` | `ec` | `ec` (P-256) or `rsa` (2048) |

- Only the tokens of an order in progress are answered at `/.well-known/acme-challenge/`
  (before authentication); any other is `404`. TLS-ALPN-01 and DNS-01 are not offered: in
  Kubernetes, cert-manager covers both (`tls.existingSecret`).
- The account key (`<home>/acme/account.key`) and the certificate's key (`key.pem`) are mode
  0600, never logged nor served.
- A failed order is logged as an error and retried after 1 minute, then doubling up to 6 hours
  (Let's Encrypt's rate limits). Alert on `testor_tls_expiry_seconds`.
- Several testors on one home: one orders (a claim), the others serve the new files within a
  minute.
- With `TESTOR_TLS_CERT`/`TESTOR_TLS_KEY` set, those serve and `tls.acme` is ignored. The Helm
  chart takes `tls.acme` (passed as `TESTOR_ACME`) and refuses it with `tls.existingSecret`.

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

## Jobs

Jobs ([jobs.md](jobs.md)) let the API start runs, so they are off until `execution.enabled`
and need authentication even then. Queuing or cancelling one needs the `execute` scope; taking
one needs `agent`, which no other role has. A job names a project and a task, never a command:
the agent runs only the commands its own `agent.json` lists, so a stolen `execute` token can
run nothing the runner's owner did not write down. A job's `ref` must look like a git ref (no
leading `-`). Run agents as the account tests run as, never as the service's.

An agent on another machine sends its runs (`/api/v1/agent/jobs/:id/run`, `/log`, `/files`).
It can write only the run of a job it holds; the record's `project`, `kind` and `job` are the
job's, whatever the agent sends, and its `pid` is dropped. A run whose record is final cannot
change. Log chunks are appended only at the log's current size (1 MB each); files keep to the
same path rules as the file routes, screenshots must be images, and a run's artifacts stay
under `artifacts.maxRunMB`. Use HTTPS (`TESTOR_TLS_CERT` or a proxy) between agents and testor.

Such an agent signs each run it sends with an ECDSA P-256 key of its own. testor pins the
first key an agent user presents and refuses any other (a stolen agent token alone cannot pass
for that agent's runs), and keeps the agent's attestation only when it matches, byte for byte,
the files it received ([attestation.md](attestation.md#signed-by-the-agent)).

With `isolate` in `agent.json`, each job runs in a worktree or copy of its project's workspace
that is removed afterwards, so one run cannot leave files (a poisoned cache, a planted
script) for the next ([jobs.md](jobs.md#isolation)).

A job's secrets are resolved by its agent, on its machine, from the sources its own
`agent.json` names (Vault, AWS, GCP, Azure secret managers, SOPS files, environment, files):
they never pass through testor, and a job cannot ask for one its project does not list. Their
values are masked in the run's log and error before anything is stored or sent; a secret that
cannot be read fails the job naming the secret only ([jobs.md](jobs.md#secrets)). Prefer
workload identities (IAM roles for service accounts, GKE and Azure workload identity, Vault's
Kubernetes login) to long-lived keys on the runner.

A job may name a snapshot instead of a ref ([snapshots](snapshots.md)). Its code is whatever
its sender uploaded, so an agent takes snapshot jobs only for projects whose `agent.json` says
`"snapshots": true`: there, the `execute` scope can run any code with that machine's commands,
as push access to a `ref` can. Contents are addressed by their SHA-256 and checked on upload,
so none can be swapped for another; manifests' paths are relative, normalized and refused with
`..`, `.git`, a drive or stream colon, or a case clash; the agent resolves each inside the
workspace and replaces any link on the way. Incremental state is data the next run reads: it is
kept per project and branch, written only by the agent holding a job of that project, and
capped in size, so another project's job cannot poison it.

A job's `select` (files, test names) is data the agent appends to its own command as separate
arguments, never through a shell; paths follow the snapshot rules. Exec mode is the one way a
job carries a command (`argv`), and it takes three opt-ins: the agent's `exec.subjects`, the
`exec` scope (the `exec-admin` role only), and a claim testor signs with its job-token key of who
asked and the argv's hash, which the agent checks. It runs in the container executor unless the
agent says otherwise, in a workspace copy of its own, and every exec job is audited
([handoff](handoff.md#exec-mode)). The result cache is per project and keyed by everything the
owner declared as an input.

testor can also be that identity: with `jobTokens` in `auth.json`, the agent holding a job's
lease gets an OpenID Connect token for it (RS256, `sub` = `project:<p>:kind:<k>`, 15 minutes by
default, for a listed audience only), which clouds and Vault trade for credentials scoped to
that project ([jobs.md](jobs.md#identity-tokens)). Its keys are published at
`/.well-known/jwks.json` with the discovery document at `/.well-known/openid-configuration`.

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

`auth.json`, `jwt.key`, `token-keys.json`, `job-token-keys.json`, `signing.key`,
`webhooks.json`, `statuses.json` and `hub.json` live in the data folder unless `TESTOR_SECRETS_DIR` names
another; testor creates its keys readable by their owner only. Test commands run as the same
account as testor (see below), so they can read these files wherever they are: moving them
protects them only once the tests run as an account that cannot read that folder. Replicas, or keys kept in a secret
store, take `TESTOR_JWT_SECRET` and `TESTOR_TOKEN_KEY` from the environment instead of files.

## Encryption at rest

testor does not encrypt the files it keeps on the runner (runs, logs, screenshots, artifacts,
keys) itself: a
key it held would sit on the same disk, next to what it protects, and videos and reports are
served by byte range straight from their files. Encrypt the storage instead:

| Where testor runs | How |
| ----------------- | --- |
| Windows | BitLocker on the drive holding the testor home (`manage-bde -on C:`), with TPM |
| Linux | LUKS (dm-crypt) on the volume, or the cloud disk's encryption |
| macOS | FileVault |
| Kubernetes | a StorageClass with encrypted volumes (EBS, Persistent Disk, Azure Disk encryption, often by default; customer-managed keys in the cloud's KMS), and encryption of Secrets in etcd (`EncryptionConfiguration`, a KMS provider) |
| Backups | encrypt the archive (`age`, `gpg`) or the bucket it goes to |

With volume encryption, what a stolen disk or snapshot holds is unreadable; what a process on
the running machine can read is not changed by it: that is what accounts, permissions and the
separate test account above are for.

### Archive to object storage

Runs can also be kept off the runner, encrypted, for as long as you must keep evidence:
`archive` in `config.json` copies each finished, signed run (record, log, screenshots,
artifacts, attestations) to an S3-compatible bucket (AWS S3, MinIO, Cloudflare R2, Google Cloud
Storage's interoperability API, Ceph, versitygw).

```json
{ "archive": {
    "bucket": "acme-test-evidence", "region": "eu-west-1", "prefix": "testor/runner-1",
    "encryption": "aws:kms", "kmsKeyId": "arn:aws:kms:eu-west-1:123456789012:key/...",
    "objectLock": { "mode": "COMPLIANCE", "days": 365 } } }
```

| Key | Meaning |
| --- | ------- |
| `bucket`, `region`, `prefix` | where; objects go under `<prefix>/runs/`, `logs/`, `screenshots/<id>/`, `artifacts/<id>/`, `attestations/` |
| `endpoint`, `pathStyle` | another server than AWS (`https://minio.example.com:9000`, `pathStyle: true`) |
| `encryption`, `kmsKeyId` | server-side encryption: `AES256` (the bucket's keys) or `aws:kms` with your key |
| `objectLock` | retention on each object (`GOVERNANCE` or `COMPLIANCE`, `days`) in a bucket with Object Lock: no one deletes or rewrites the evidence before then, the runner's credentials included |

- Each object carries its SHA-256 (`x-amz-checksum-sha256`), which the server checks; requests
  are signed with SigV4 (no SDK in the release).
- Credentials as AWS's SDKs take them: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_SESSION_TOKEN`, or `AWS_ROLE_ARN` with `AWS_WEB_IDENTITY_TOKEN_FILE` (IAM roles for
  service accounts) traded with STS. Give them `s3:PutObject` on the prefix only: testor never
  reads, lists or deletes there.
- A run is archived once it ends and is signed; a failure is tried again three times, then
  logged. `archived` on the run says it is there (`<home>/archive/<id>.json` lists the keys).
  Deleting a run on the runner leaves its archive.
- The archive is evidence kept apart; [runs in object storage](storage.md) (`storage`) is
  where testor itself keeps runs instead of its home. Its presigned links last five minutes and
  are made only after testor's own access check; HTML and text are never linked to the bucket,
  only served by testor in its sandbox.

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

Nothing in the API runs a command it names: commands reach a runner over SSH, or as
[jobs](jobs.md) (opt-in, scope `execute`), which name a project and a task whose command the
agent's own configuration holds. Maintenance
deletes only a fixed list of targets named by id (never a path from a request), is off until
`maintenance.enabled`, and needs the `maintain` scope. testor runs as the installing user (on
Windows with a limited token), unless it is set up in an account of its own
([above](#running-tests-in-a-separate-account)).
