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

**One runner or several?** Today, each runner has its own testor and dashboard; your project's
Taskfile picks a runner per task. A hub that shows every runner in one place is on the
[roadmap](../project/roadmap.md).

## On premises and cloud native

testor today is **on-premises-first**: a service installed on the machine that runs the tests,
with no external dependency, database or account. A cloud VM is the same thing in someone
else's data center. Container images, a Helm chart, ephemeral runners and object storage for
artifacts are planned (milestones 0.3 to 0.6 of the [roadmap](../project/roadmap.md)); this
documentation describes what works now and labels anything planned.
