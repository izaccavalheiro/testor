---
sidebar_position: 11
title: Authentication and access
description: Users, roles and scopes, Bearer tokens for programs, signed links, rate limiting and the audit log.
---

# Authentication and access

Authentication is **off until you add the first user**. A fresh install works at once on a
private network; once anyone else can reach the port, turn it on.

People can also sign in with your company's identity provider instead of a password: see
[single sign-on](single-sign-on.md).

## Add users

From the workstation (the password travels on the SSH session's stdin, never on a command
line):

```sh
read -rs TESTOR_PASSWORD; export TESTOR_PASSWORD   # 12 characters or more
task testor:user USER=ada ROLE=admin
task testor:user USER=ci  ROLE=operator
task testor:token USER=ci DAYS=30 SCOPE="read operate"   # prints a Bearer token
```

The change applies within a second, without a restart. The dashboard then asks for a user name
and password (HTTP Basic); programs use Basic or a Bearer token.

## Roles and scopes

| Role | Scopes | Can |
| ---- | ------ | --- |
| `viewer` | `read` | see runs, logs, specs, screenshots, artifacts, device stats, maintenance scans |
| `operator` | `read operate` | also cancel and delete runs, run the janitor, start a maintenance scan |
| `admin` | `read operate maintain` | also delete maintenance targets |

A token carries a subset of its user's scopes, and is checked against the user on every
request: removing a user, lowering a role or revoking takes effect at once. Only a password can
obtain a token, so a leaked token cannot renew itself.

Tokens are signed with Ed25519, and the public keys are published at
`/.well-known/jwks.json`: a gateway, a hub or another service checks a testor token with any
JWT library, without holding a secret. Tokens from before 0.8 (HS256) keep working. See
[tokens](../reference/security.md#tokens) for rolling the key.

## Manage users and tokens

On the runner, through the installed release (`bin\testor.bat` on Windows):

```sh
bin/testor eval 'Testor.Auth.CLI.list'
bin/testor eval 'Testor.Auth.CLI.revoke ~s[ada]'     # tokens issued until now stop working
bin/testor eval 'Testor.Auth.CLI.remove ~s[ada]'
bin/testor eval 'Testor.Auth.CLI.roll_token_key'      # a new token key; tokens of the old one live out their time
bin/testor eval 'Testor.Auth.CLI.rotate_key'          # every token and signed link stops working
bin/testor eval 'Testor.Auth.CLI.enable false'        # off again, users kept
```

## Signed links

Browsers load images, videos and reports without sending an `Authorization` header, so with
authentication on, screenshot and artifact URLs carry a signature
(`/s/<expiry>.<hmac>/shots/<run>/...`), valid one to two days and only for that run's files.
They can be shared with someone who has no account, for that time.

## What else protects it

- **Passwords**: PBKDF2-HMAC-SHA256, 600,000 iterations, random salt.
- **Tokens**: HS256 JWT only; any other algorithm is refused before the signature is checked.
  60 minutes by default, 30 days at most.
- **Brute force**: 10 failures in 15 minutes from an address are answered `429` until the window
  ends.
- **Cross-site requests**: a `POST` or `DELETE` from another origin is refused; without a Bearer
  token it needs `X-Testor: 1` or a JSON body, which a cross-site form cannot send.
- **Audit**: every state-changing request is logged with who, from where and the result.
- **Fail closed**: an unreadable `auth.json` or signing key locks everything but the health
  checks, and says why in `testor.log`.

## Caveats

- testor speaks plain **HTTP** unless it has a certificate (`TESTOR_TLS_CERT`,
  `TESTOR_TLS_KEY`). Without one, use it over Tailscale (encrypted) or put a TLS proxy in front
  ([reverse proxy and TLS](../operations/reverse-proxy-tls.md)); otherwise passwords and tokens
  cross the network readable.
- Users are local to each runner; there is no single sign-on yet (OpenID Connect is on the
  [roadmap](../project/roadmap.md)).
- Users can be limited to **projects** (`task testor:projects USER=ci PROJECTS="web lib-*"`):
  everything else answers as if it did not exist ([details](../reference/security.md#projects)).
- Authentication covers testor's HTTP interfaces. Who can **run** commands is decided by SSH
  keys on the runner and, for [jobs](jobs-and-agents.md), by the `execute` scope together with the
  commands each agent's own configuration lists.

Full model: [Security](../reference/security.md).
