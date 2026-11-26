# Storage, queue and event ports

Status: in progress. Done (0.10): an archive of signed runs to S3-compatible storage
(`Testor.Archive`, SigV4 without a dependency); the job queue in PostgreSQL
(`Testor.Jobs.Postgres`, behind the same calls as the files' `Testor.Jobs.FileStore`); several
testors on one shared home and one PostgreSQL (`Testor.Cluster`: claims for what must happen
once, shared approvals, an audit trail per testor). Next: SQS FIFO and NATS JetStream for jobs
(0.17), S3 as the primary store with the run index and live events in PostgreSQL (0.18), which
drops the shared volume. SQLite and Redis are dropped ([decisions](README.md#decisions)).

Today the run index is in ETS, filled by scanning `runs/*.json` every 300 ms, and logs,
screenshots and artifacts are files. That keeps the install a single binary, and limits it to
one node with a local disk.

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
