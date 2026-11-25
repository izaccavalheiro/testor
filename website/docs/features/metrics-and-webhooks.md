---
sidebar_position: 14
title: Metrics and webhooks
description: Prometheus metrics of runs, jobs and the machine, and signed webhooks when a run ends.
---

# Metrics and webhooks

- **Prometheus** at `GET /metrics` (scope `read`): runs by status, the latest result and duration
  of every task, jobs by status (what an autoscaler scales agents on), event streams, disk,
  stored bytes, CPU and memory. The Helm chart has a `ServiceMonitor`.
- **Webhooks**: when a run ends, testor POSTs it to the endpoints in `webhooks.json` (in the
  secrets folder, never set through the API), signed with HMAC-SHA256 over the timestamp and
  body, and tried again on failure. Use them to post to chat, gate a pipeline or start a deploy.
- **Flaky specs**: `GET /api/v1/projects/<project>/flaky` lists spec files that passed and
  failed on one clean commit.

Details: [HTTP API](../reference/api.md#prometheus-metrics).
