# Identity

Status: done: single sign-on, asymmetric tokens, users limited to projects and the secrets
broker, identity tokens for jobs and a role per project (0.8); signed links bound to the
viewer and minutes long (0.13). Builds
on: users, roles and scopes; HS256 tokens; signed links (0.2).

- **OpenID Connect sign-in** (done, 0.8) for the dashboard (authorization code with PKCE, a
  session cookie: `HttpOnly`, `Secure`, `SameSite=Lax`), groups or claims mapped to roles;
  Basic stays for scripts and as a break-glass account.
- **Asymmetric tokens** (done, 0.8): testor's own tokens signed with EdDSA and published as
  JWKS, so a verifier (a hub, an agent) needs no secret; HS256 accepted until the next major
  version.
- **Projects and teams** (users limited to projects, a role per project: done, 0.8): a role
  per project (`viewer`, `operator`, `admin`), filtering every list, event stream and MCP
  tool; signed links bound to the viewer and minutes long (done, 0.13: `/s/v2.`, `linkMinutes`).
- **Workload identity**: jobs ([agent-protocol.md](agent-protocol.md)) get a short OIDC token
  from testor (issuer, audience, `sub` = project, kind and commit) to exchange for cloud
  credentials, as GitHub Actions does (done, 0.8: `jobTokens`); a secrets broker (done, 0.8: the agent reads
  Vault, AWS, GCP, Azure secret managers, SOPS files with the machine's own identity) hands
  secrets to a job by name, and their values are masked in its logs by the agent before
  anything leaves the runner.
