# Job queues on a broker

By default testor's own store dispatches jobs: files on one testor, PostgreSQL across several
(`TESTOR_DATABASE_URL`). With `execution.queue` in config.json, a broker does: Amazon SQS
(FIFO queues), or NATS JetStream. Agents do not change: they lease through testor's API and
never hold broker credentials.

## What the broker does, and what it does not

The broker **dispatches**; job **records** (status, history, attempts, the run) stay in the
store. A message holds a job's id and project; testor reads everything else from its own
record, so a forged message cannot carry a command or labels.

| testor | SQS FIFO | NATS JetStream |
| ------ | -------- | -------------- |
| queue a job | `SendMessage`, group = project, deduplication id = job id | publish to the queue's subject, `Nats-Msg-Id` = job id |
| lease | `ReceiveMessage`, visibility timeout = the lease | pull consumer `MSG.NEXT`, `ack_wait` = the lease |
| heartbeat | `ChangeMessageVisibility` | `+WPI` |
| finish, expire | `DeleteMessage` | `+ACK` |
| lease runs out, retried | the message comes back | redelivery |
| cancelled while queued | deleted when next received | acknowledged when next received |
| one job per project | the FIFO group keeps one message in flight | the store's check, `-NAK` when busy |

A job the broker refuses is not left queued (it ends `cancelled`, "the queue did not take it",
and the API answers 503). Jobs queued before a broker was configured are not dispatched by it.

## Queues and labels

`queues` maps labels to queues: a job goes to the first queue whose labels it carries all of,
and is refused when none fits; an agent receives from every queue whose labels it has. Put the
catch-all queue (`"labels": []`) last.

## SQS

```json
"execution": { "enabled": true, "queue": {
  "type": "sqs", "region": "eu-west-1",
  "queues": [
    { "labels": ["mutation"], "url": "https://sqs.eu-west-1.amazonaws.com/123456789012/testor-heavy.fifo" },
    { "labels": [], "url": "https://sqs.eu-west-1.amazonaws.com/123456789012/testor-jobs.fifo" } ] } }
```

Credentials are the archive's (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, or a web identity:
`AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`, as on EKS). Queues must be FIFO and HTTPS
(`allowHttp: true` for a local ElasticMQ). The queue and its policy, in Terraform:

```hcl
resource "aws_sqs_queue" "jobs" {
  name                        = "testor-jobs.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  visibility_timeout_seconds  = 30
  sqs_managed_sse_enabled     = true # or kms_master_key_id
}

data "aws_iam_policy_document" "testor" {
  statement {
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:ChangeMessageVisibility", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.jobs.arn]
  }
}
```

testor counts attempts itself (`execution.maxAttempts`), so a dead-letter queue is optional.

## NATS JetStream

```json
"execution": { "enabled": true, "queue": {
  "type": "nats", "url": "tls://nats.example.com:4222", "stream": "TESTOR",
  "auth": { "credsFile": "/run/secrets/testor.creds" },
  "queues": [ { "labels": [], "subject": "testor.jobs.default" } ] } }
```

- TLS is required (`nats://` only with `"tls": false`, for a broker on the same machine);
  `caBundle` adds CAs to trust.
- `auth`: `token`, `user`/`password` (values may be `env:NAME`), `nkeySeedFile`, or
  `credsFile` (a user JWT and its NKey seed).
- testor makes the stream (`WorkQueue` retention) and a durable pull consumer per subject
  (`testor-<subject with _>`) when missing; the consumer's `ack_wait` is the lease at the time.

testor speaks NATS's text protocol itself (no dependency), one connection per operation.

## Scaling agents on the queue

With a broker, the chart's KEDA trigger can read the broker: `agents.autoscaling.trigger` (or
a profile's) replaces the Prometheus query, for example `type: aws-sqs-queue` with the queue
URL, or `type: nats-jetstream` with the stream and consumer. Give the scaler an identity that
can read queue depth only.

## Health and metrics

`/api/health` reports `queue: ok`, or `degraded` when a broker call failed in the last minute
(queued jobs wait; testor keeps serving). `/metrics` has `testor_queue_depth{queue}` and
`testor_queue_errors_total`.

## RabbitMQ

Not built. AMQP is a binary protocol, and a client means a heavy dependency (`amqp` brings
`amqp_client` and `rabbit_common`). If someone needs it, it would come as an optional
dependency compiled only on request; until then, use PostgreSQL, SQS or NATS.
