---
sidebar_position: 3
title: Choosing where to run it
description: On premises or in the cloud, one runner or several, private network or the internet - which setup fits.
---

# Choosing where to run it

A runner is any machine with an SSH server and PowerShell 7. testor does not care whether it
is under your desk or in a data center; what changes is how you reach it and protect it.

| Setup | Good for | Network | Protect with | Scenario |
| ----- | -------- | ------- | ------------ | -------- |
| **A spare machine at home or in the office** | one developer, the platform you do not run (Windows from Linux, macOS from Windows) | LAN or Tailscale | Tailscale's encryption; auth optional | [Home lab over Tailscale](../scenarios/home-lab-tailscale.md) |
| **A shared machine for a team** | several people, one GPU box or one Mac | LAN or Tailscale | users with roles; tokens for CI | [Team runner](../scenarios/team-runner.md) |
| **A cloud VM** | no spare hardware; big CPU or GPU on demand | Tailscale, or the internet behind TLS | TLS proxy, `TESTOR_BIND=127.0.0.1`, users | [Cloud VM runner](../scenarios/cloud-vm-runner.md) |
| **Several runners** | Windows *and* macOS *and* Linux | each reached by its own SSH host | per runner | [Several runners](../scenarios/several-runners.md) |
| **Runners elsewhere, one testor** | machines behind NAT or in other networks, reporting to one dashboard | agents connect out over HTTPS; no inbound port | users, an agent user and key per agent, TLS | [Jobs and agents](../features/jobs-and-agents.md) |
| **Containers and Kubernetes** | dashboards in a cluster, autoscaled test pods | the Helm chart; agent pods scaled by KEDA | the chart's hardened pods, NetworkPolicy, TLS | [Jobs and agents](../reference/jobs.md#agents-in-containers-and-kubernetes) |

## Decision points

**Which OS?** The one your users run, or the one you cannot test locally. Windows runners have
the richest device statistics (GPU load per engine, per-core CPU, disk read and write);
Linux is close; macOS reports less ([device stats](../features/device-stats.md#platform-differences)).

**Which network?** Tailscale is the simplest secure option: encrypted end to end, works across
NAT, gives the runner a stable name, and the Windows installer's firewall rule already allows
its range. Plain LAN works too; give the runner a fixed address. **Never expose port 6767 to the
internet as plain HTTP**: put a TLS proxy in front ([reverse proxy and TLS](../operations/reverse-proxy-tls.md)).

**Turn on authentication?** Yes as soon as anyone but you can reach the port. It is off on a
fresh install so a private setup works at once.

**One runner or several?** Over SSH, each runner has its own testor and dashboard, and your
project's Taskfile picks a runner per task. For one dashboard over many machines, run one
testor and an agent on each machine. A hub across several testors is on the
[roadmap](../project/roadmap.md).

## On premises and cloud native

testor is **on-premises-first**: a service with no external dependency, database or account,
installed on the machine that runs the tests (from source or a checked prebuilt release). The
same release runs as a **container** (`ghcr.io/izaccavalheiro/testor`, Compose or Kubernetes
with the Helm chart), and tests run in containers or Kubernetes through **agents**, autoscaled
on queued jobs. Object storage for artifacts, a database for the run index and a hub across
testors are on the [roadmap](../project/roadmap.md); this documentation describes what works
now and labels anything planned.
