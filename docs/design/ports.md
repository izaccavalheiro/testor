# Storage, queue and event ports

Status: in progress. Done (0.10): an archive of signed runs to S3-compatible storage
(`Testor.Archive`, SigV4 without a dependency); the job queue in PostgreSQL
(`Testor.Jobs.Postgres`, behind the same calls as the files' `Testor.Jobs.FileStore`); several
testors on one shared home and one PostgreSQL (`Testor.Cluster`: claims for what must happen
once, shared approvals, an audit trail per testor). SQLite and Redis are dropped ([decisions](README.md#decisions)).

**Object storage (0.13):** `Testor.Blob` is the object store port (`Testor.Blob.Files`, a
folder; `Testor.Blob.S3`, any S3-compatible bucket, SigV4 in `Testor.Aws`), and
`Testor.Storage` keeps runs in a bucket with the home as a cache ([storage](../storage.md)).
With PostgreSQL too, the run index is the table `testor_runs` instead of the scan of
`runs/*.json`, and live events between testors go over `LISTEN`/`NOTIFY`
(`Testor.Storage.Shared`, through Postgrex: no new dependency), so testors share no volume.
The audit trail goes to the bucket in segments; attestations are made and checked as before,
from the files fetched into the home. Azure Blob is not built yet (it would be `Blob.Azure`,
SharedKey or Entra workload identity, tested against Azurite); Google Cloud Storage works
through its S3-compatible XML API.

Without `storage`, the run index is in ETS, filled by scanning `runs/*.json` every 300 ms, and
logs, screenshots and artifacts are files: a single binary on one node with a local disk.

**Queues (0.13):** `Testor.Queue` is the queue port: SQS FIFO (`Testor.Queue.SQS`) and NATS
JetStream (`Testor.Queue.NATS`, a client of its text protocol) dispatch jobs while their
records stay in the store ([queues](../queues.md)). **RabbitMQ: not built.** AMQP needs a
binary-protocol client, which means a heavy dependency (`amqp_client`, `rabbit_common`); it
would come only on request, as an optional dependency. PostgreSQL, SQS and NATS cover the need.

Each concern becomes an Elixir behaviour with today's code as its default adapter:

| Port | Default (no dependency) | Adapters |
| ---- | ----------------------- | -------- |
| `Testor.Store` run index | files + ETS (today) | PostgreSQL (several controllers) |
| `Testor.Blob` logs, screenshots, artifacts, attestations | files (today) | S3 and compatibles (MinIO, R2), GCS, Azure Blob; signed URLs replace `/s/` links |
| `Testor.Queue` jobs ([agent-protocol.md](agent-protocol.md)) | in-process | PostgreSQL (`SKIP LOCKED`, done), SQS FIFO, NATS JetStream; RabbitMQ decided last |
| `Testor.Events` live updates | `Registry` (today) | PostgreSQL `LISTEN`/`NOTIFY` |

Rules: the files adapters stay the default and keep passing the whole suite; an adapter is a
separate optional dependency (the release does not grow for those who do not use it); every
adapter runs the same contract tests; the audit trail and attestations are written through
`Blob` with their verification unchanged.
