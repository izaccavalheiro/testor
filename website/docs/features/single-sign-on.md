---
sidebar_position: 11.5
title: Single sign-on
description: Sign in to the dashboard with your identity provider (OpenID Connect), groups mapped to roles and projects.
---

# Single sign-on

People sign in to the dashboard with the identity provider they already use: Entra ID,
Google, Okta, Keycloak, Authentik, Dex, GitLab or any other OpenID Connect provider. Their
groups decide what they can do and which projects they see. Nobody needs a testor password.

## Set it up

1. Register testor with the provider as a **web application**, with the redirect URI
   `https://<your testor>/auth/callback`, and have it put the user's groups in the ID token
   (often a `groups` claim or scope).
2. Add an `oidc` section to `auth.json` on the runner:

   ```json
   {
     "oidc": {
       "issuer": "https://login.example.com/realms/eng",
       "clientId": "testor",
       "clientSecret": "...",
       "redirectUri": "https://testor.example.com/auth/callback",
       "roles": { "admin": ["platform"], "operator": ["qa"], "viewer": ["*"] },
       "projects": { "web-team": ["web", "web-*"], "platform": ["*"] }
     }
   }
   ```

   Keep the secret out of the file with `TESTOR_OIDC_CLIENT_SECRET` if you prefer.
3. testor applies it within a second: open the dashboard, and you are sent to the provider.

## Who gets what

- **Roles**: the groups of each role. `*` means anyone the provider signs in. The highest
  role that matches wins: `admin`, then `operator`, then `viewer`. Someone in no listed group
  is refused.
- **Projects**: the projects each group sees (`*` as a group applies to everyone; `*` as a
  project means all). Someone in several groups sees all of their projects. Leave `projects`
  out and everyone sees every project.

A session lasts 8 hours (`sessionHours`). Changes of someone's groups apply at their next
sign-in. To end every session at once, set `sessionsValidAfter` to the current Unix time.

## Passwords still work

Users in `auth.json` keep working: scripts and CI use their tokens as before, and
`https://<your testor>/?basic` signs in with a password. Keep one admin there as a
break-glass account for when the provider is down.

## Safety

The code flow with PKCE, `state` and `nonce`; ID tokens checked against the provider's keys,
issuer, audience, expiry and nonce; a session cookie that is `HttpOnly`, `SameSite=Lax` and
`Secure` over HTTPS, and cannot be used as an API token. Refused sign-ins are logged, audited
and rate limited. The [security model](../reference/security.md#single-sign-on-openid-connect)
has the details.
