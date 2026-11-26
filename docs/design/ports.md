# Storage, queue and event ports

Status: in progress. Done (0.10): an archive of signed runs to S3-compatible storage
(`Testor.Archive`, SigV4 without a dependency); the job queue in PostgreSQL
(`Testor.Jobs.Postgres`, behind the same calls as the files' `Testor.Jobs.FileStore`); several
testors on one shared home and one PostgreSQL (`Testor.Cluster`: claims for what must happen
once, shared approvals, an audit trail per testor). S3 as the primary store would drop the
shared volume.

Today the run index is in ETS, filled by scanning `runs/*.json` every 300 ms, and logs,
screenshots and artifacts are files. That keeps the install a single binary, and limits it to
one node with a local disk.

**Queues (0.17):** `Testor.Queue` is the queue port: SQS FIFO (`Testor.Queue.SQS`) and NATS
JetStream (`Testor.Queue.NATS`, a client of its text protocol) dispatch jobs while their
records stay in the store ([queues](../queues.md)). **RabbitMQ: not built.** AMQP needs a
binary-protocol client, which means a heavy dependency (`amqp_client`, `rabbit_common`); it
would come only on request, as an optional dependency. PostgreSQL, SQS and NATS cover the need.

Each concern becomes an Elixir behaviour with today's code as its default adapter:

| Port | Default (no dependency) | Adapters |
| ---- | ----------------------- | -------- |
| `Testor.Store` run index | files + ETS (today) | SQLite (single node), PostgreSQL (several controllers) |
| `Testor.Blob` logs, screenshots, artifacts, attestations | files (today) | S3 and compatibles (MinIO, R2), GCS, Azure Blob; signed URLs replace `/s/` links |
| `Testor.Queue` jobs ([agent-protocol.md](agent-protocol.md)) | in-process | PostgreSQL (`SKIP LOCKED`), RabbitMQ, NATS JetStream, SQS |
| `Testor.Events` live updates | `Registry` (today) | Phoenix.PubSub on PostgreSQL `NOTIFY` or Redis |

Rules: the files adapters stay the default and keep passing the whole suite; an adapter is a
separate optional dependency (the release does not grow for those who do not use it); every
adapter runs the same contract tests; the audit trail and attestations are written through
`Blob` with their verification unchanged.
