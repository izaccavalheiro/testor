# Run attestations

When a run ends, testor signs what it observed: the run's record and the SHA-256 of its log,
screenshots and artifacts. A CI job, a release gate or an auditor can later check that a run
passed, on which runner, and that none of its files changed since, without trusting the
dashboard or the files on the runner.

## Format

An [in-toto Statement v1](https://github.com/in-toto/attestation/blob/main/spec/v1/statement.md)
in a [DSSE envelope](https://github.com/secure-systems-lab/dsse/blob/master/envelope.md), signed
with Ed25519:

```json
{
  "payloadType": "application/vnd.in-toto+json",
  "payload": "<base64 of the statement>",
  "signatures": [{ "keyid": "<SHA-256 of the public key's DER>", "sig": "<base64>" }]
}
```

The statement:

| Field | Value |
| ----- | ----- |
| `_type` | `https://in-toto.io/Statement/v1` |
| `subject` | `log`, `screenshots/<path>`, `artifacts/<path>`, each with `digest.sha256` |
| `predicateType` | `https://github.com/izaccavalheiro/testor/blob/main/docs/attestation.md#run-v1` |
| `predicate` | see below |

### run-v1

| Field | Meaning |
| ----- | ------- |
| `run` | the run record when it ended: `id`, `project`, `kind`, `command`, `status`, `exitCode`, `error`, `warning`, `startedAt`, `endedAt`, `durationMs`, `summary` (spec files and tests passed, failed, skipped), `actor`, `screenshots`, `artifacts` |
| `runner` | `host` (the machine's name), `os` (`windows`, `linux`, `macos`), `testor` (its version) |
| `signedAt` | when testor signed it (UTC) |

## Getting one

```sh
curl -s -u ada http://my-runner:6767/api/v1/runs/<id>/attestation > envelope.json
curl -s -u ada http://my-runner:6767/api/v1/attestation/key | jq -r .publicKey > testor.pem
```

Attestations are written a moment after a run ends (hashing large artifacts takes time); the
run's `attested` field says when one exists. They are deleted with the run.

Keep a copy of the public key from a time you trust (pin it in CI): a key fetched together with
the attestation proves only that the runner signed it, not which runner.

## Verifying it

With `jq` and OpenSSL 3:

```sh
type=$(jq -r .payloadType envelope.json)
jq -r .payload envelope.json | base64 -d > payload.json
jq -r '.signatures[0].sig' envelope.json | base64 -d > sig.bin
# DSSE's pre-authentication encoding: "DSSEv1 <len(type)> <type> <len(payload)> <payload>"
printf 'DSSEv1 %d %s %d ' "${#type}" "$type" "$(wc -c < payload.json)" > pae.bin
cat payload.json >> pae.bin
openssl pkeyutl -verify -pubin -inkey testor.pem -rawin -in pae.bin -sigfile sig.bin
jq -e '.predicate.run.status == "passed"' payload.json   # a gate
```

To check a file against it: `sha256sum` the file and compare with its subject's digest.

## The key

`signing.key` in the secrets folder (`TESTOR_SECRETS_DIR`, else the testor home): the Ed25519
seed in base64, created on first use, readable by its owner only. Deleting it makes a new key
on the next run: earlier attestations stay valid under the old public key, so keep it.

## What a signature proves

That this testor saw these results and these files when the run ended, and that they have
not changed since. The run record itself is written by `run.ps1` in the account the tests run
as, and the spec summary is parsed from the run's output. A test that is malicious, in an
account that can also read `signing.key`, can make testor sign anything. Signatures become
evidence when tests run in an account that cannot read the secrets folder; see
[security.md](security.md#what-stays-out-of-reach).

## Signed by the agent

A run that an agent on another machine sent ([jobs](jobs.md)) is also signed by the agent
itself, so its evidence does not rest on testor alone: what the agent ran, and the files it
produced, as the agent saw them.

- **The key.** Each agent makes an ECDSA P-256 key on its first start (`agent.key` in its home,
  readable by its owner only) and presents the public half with each lease. testor pins the
  first key an agent user presents (trust on first use) in `agent-keys.json` in the secrets
  folder and refuses any other: give each agent a user of its own. A rebuilt agent's new key
  is accepted once its old one is forgotten:
  `bin/testor eval 'Testor.Auth.CLI.forget_agent_key ~s[name]'`. `GET /api/v1/agents` lists the
  pinned keys.
- **The statement.** At the run's end the agent signs an in-toto statement in a DSSE envelope
  (`predicateType` `…/docs/attestation.md#agent-run-v1`): its subjects are the log, screenshots
  and artifacts it sent, with their SHA-256; its predicate the run (`id`, `job`, `project`,
  `kind`, `command`, `status`, `exitCode`, times) and the agent's `host`.
- **The check.** testor keeps it only if the signature is the pinned key's, it names this run
  and job, and its subjects are exactly the files testor received with the digests testor
  computes, so nothing was lost or changed on the way. The run then has `agentAttested`;
  `GET /api/v1/runs/<id>/attestation?by=agent` gives the envelope.

Verify it with OpenSSL (the signature is DER, over the same pre-authentication encoding):

```sh
curl -s -u ada "http://my-runner:6767/api/v1/runs/<id>/attestation?by=agent" > envelope.json
# the agent's key, from GET /api/v1/agents or from the agent's machine
type=$(jq -r .payloadType envelope.json)
jq -r .payload envelope.json | base64 -d > payload.json
jq -r '.signatures[0].sig' envelope.json | base64 -d > sig.der
printf 'DSSEv1 %d %s %d ' "${#type}" "$type" "$(wc -c < payload.json)" > pae.bin
cat payload.json >> pae.bin
openssl dgst -sha256 -verify agent.pem -signature sig.der pae.bin
```

A local agent (on testor's machine) writes its runs into testor's home and signs nothing of
its own: testor's attestation is the evidence there.

