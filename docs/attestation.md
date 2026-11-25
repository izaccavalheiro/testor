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
