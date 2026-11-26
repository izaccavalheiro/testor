# Runs in object storage

By default the home is the store: run.ps1 and testor write a run's record, log, screenshots,
artifacts, reports and attestations under `<home>` (`runs/`, `logs/`, `screenshots/`,
`artifacts/`, `reports/`, `attestations/`), and testors that serve one team share that home on
one volume.

With `storage` in config.json, an S3-compatible bucket is the store and the home is a cache:

```json
{
  "storage": {
    "type": "s3",
    "bucket": "acme-testor",
    "region": "eu-west-1",
    "endpoint": "https://minio.example.com",
    "pathStyle": true,
    "prefix": "testor",
    "publicEndpoint": "https://files.example.com",
    "encryption": "aws:kms",
    "kmsKeyId": "arn:aws:kms:eu-west-1:111122223333:key/...",
    "presign": true,
    "cacheMB": 2048
  }
}
```

| Key | Meaning |
| --- | ------- |
| `bucket`, `region` | required |
| `endpoint` | the server's URL, when it is not AWS (MinIO, R2, Ceph, versitygw, Google Cloud Storage's `https://storage.googleapis.com`) |
| `pathStyle` | `https://host/bucket/key` instead of `https://bucket.host/key` (MinIO and most compatibles) |
| `prefix` | a folder of the bucket for this testor's runs |
| `publicEndpoint` | the URL browsers reach the bucket by, for presigned links (default: `endpoint`) |
| `encryption`, `kmsKeyId` | `AES256` (SSE-S3) or `aws:kms` (SSE-KMS, with its key) on every object |
| `presign` | `false`: testor serves every file itself, and browsers never reach the bucket |
| `cacheMB` | how much of the home the stored runs' files may take (default 2048) |

Credentials come as AWS SDKs take them: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (with
`AWS_SESSION_TOKEN`), or `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` (IAM roles for service
accounts), traded with STS. The storage is read when testor starts: a change needs a restart.

## What is kept where

A run's objects have the keys its files have in the home, under `prefix`:

| Key | What |
| --- | ---- |
| `runs/<id>.json` | the record, with `"stored": true` |
| `logs/<id>.log` | the log, once the run has ended |
| `logs/<id>/<offset>.log` | the log while it runs, in segments (testors without a shared volume) |
| `screenshots/<id>/...`, `artifacts/<id>/...` | as the run left them |
| `reports/<id>/...`, `reports/<id>.*.json` | its report files, and what testor read from them |
| `attestations/<id>.dsse.json`, `attestations/<id>.agent.dsse.json` | testor's and its agent's signatures |
| `audit/<instance>/<yyyy-mm-dd>/<ms>.jsonl` | the audit trail, sent every 10 s |

Every object carries its SHA-256 (`x-amz-checksum-sha256`), which the server checks; a file
over 64 MB goes in 16 MB parts, each with its own checksum.

## How a run moves

1. While it runs, the run is in the home of the testor that follows it (run.ps1's, or the one
   its agent sends it to); an agent's screenshots, artifacts and reports go to the bucket as
   they arrive.
2. When it ends, testor reads its log and reports (fetching from the bucket what reached
   another testor), signs it over all its files, uploads what the bucket lacks, then its record.
3. A testor that lacks a stored run's files fetches them when they are first read: the log,
   reports and attestations as files in its home; screenshots and artifacts are listed from the
   bucket and served as below.
4. Every 10 minutes the home is trimmed to `cacheMB`: the oldest stored runs lose their local
   files (their records stay), and are fetched again if they are read.
5. Deleting a run deletes its objects; objects under Object Lock or a legal hold stay, as the
   bucket keeps them.

A testor alone (no `TESTOR_DATABASE_URL`) that starts on an empty home restores its runs'
records from the bucket.

## Serving files

What a browser shows in testor's sandbox (HTML reports, text, JSON, SVG, PDF) is fetched and
served by testor, with its `sandbox` content security policy, which a bucket cannot set.
Images, videos and downloads get a presigned link instead (a `302` to the bucket, valid five
minutes), after the request has passed testor's own access check (a signed in user who may see
the project, or a file link bound to its viewer); a download's link names it an attachment.
A file the run's listing lacks gets a `404`, never a link.

## Testors without a shared volume

With `storage` in S3 and `TESTOR_DATABASE_URL`, several testors serve one team with no volume
in common. What each sees of the others' runs goes through PostgreSQL:

- **The run index**, the table `testor_runs` (id, project, status, start and end, commit,
  branch, the record as `jsonb`, a version, the log's size, the testor it runs on). Each
  testor loads it at start, follows its changes, and catches up every 30 s. A finished record
  is never turned back into a running one.
- **Live logs:** an agent's log chunk becomes a segment in the bucket, and the index's log size
  moves only from the offset the segment starts at, so an agent's retry through another testor
  is never appended twice. A local run's log goes in segments of 256 KB or 5 s. Every testor
  appends the segments to its copy of the log as `NOTIFY` announces them (fetching any it
  missed), so its live view and spec parsing work as for a run of its own.
- **Events:** `NOTIFY testor_relay` carries runs' changes and removals, log segments (inline up
  to 5 KB, else read from the bucket) and the dashboard's `job` and `approval` events, under
  NOTIFY's 8 KB.

Jobs, claims and approvals are already in PostgreSQL ([queues](queues.md)).

## The bucket

Keep it private and TLS only, for example (AWS):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TLSOnly",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::acme-testor", "arn:aws:s3:::acme-testor/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
```

with S3 Block Public Access on. testor needs `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`
and `s3:ListBucket` on it (`s3:AbortMultipartUpload` too, for large files).

| Store | Notes |
| ----- | ----- |
| AWS S3 | virtual-hosted style by default; SSE-KMS, Object Lock for retention |
| MinIO, Ceph, versitygw | `pathStyle: true`; versitygw runs in CI |
| Cloudflare R2 | `endpoint: https://<account>.r2.cloudflarestorage.com`, `region: auto` |
| Google Cloud Storage | its XML API (`endpoint: https://storage.googleapis.com`) with HMAC keys; not tested in CI |
