---
sidebar_position: 13
title: Signed results and audit
description: Every finished run signed as an in-toto attestation, runs from agents signed by the agent too, and a tamper-evident audit trail.
---

# Signed results and audit

testor keeps evidence you can check without trusting the dashboard.

- **Every finished run is signed** by testor: an in-toto statement in a DSSE envelope (Ed25519)
  holding the run's record and the SHA-256 of its log, screenshots and artifacts.
  `GET /api/v1/runs/<id>/attestation`, verifiable with OpenSSL.
- **Release gates**: `GET /api/v1/gates/<gate>?commit=<sha>` says whether a commit may ship:
  each kind's latest run of it passed, and its signature holds. For a deploy pipeline, or as
  the input of an OPA policy.
- **Runs from agents are signed by the agent too**, with an ECDSA P-256 key testor pins to it,
  and kept only when they match, byte for byte, what testor received.
  `GET /api/v1/runs/<id>/attestation?by=agent`.
- **The audit trail** (`audit.jsonl`): every state-changing request and failed sign-in, each
  entry chained to the one before and signed, so an edited, removed or reordered entry shows.
  `GET /api/v1/audit` (scope `maintain`) checks the whole chain.
- **Who started a run**: the account and SSH client the runner saw, or the agent and who asked
  for the job.

How to verify them: [run attestations](../reference/attestation.md). What a signature proves,
and when: [security model](../reference/security.md).
