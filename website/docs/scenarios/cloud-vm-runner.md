---
sidebar_position: 9
title: A runner in the cloud
description: Run testor on a Linux or Windows VM in any cloud, reached through Tailscale or behind a TLS proxy.
---

# A runner in the cloud

**The situation.** You have no spare hardware, or you need more cores or a GPU than you own.
A VM in any cloud (AWS, Azure, Google Cloud, Hetzner, DigitalOcean, ...) is a runner like any
other: an SSH server and PowerShell 7.

## Pick the VM

- **Linux**: Ubuntu 24.04 LTS or Debian 12. 4 vCPU and 8 GB of memory run most Node.js suites
  comfortably; end-to-end suites like more.
- **Windows**: Windows Server 2022/2025 works like Windows 10/11 for testor (scheduled task,
  firewall rule).
- **Disk**: 40 GB or more; dependencies and caches grow.

## Option A: private, through Tailscale (recommended)

Open **no** inbound port except SSH (or not even SSH: Tailscale SSH works too).

```sh
# on the VM
curl -fsSLO https://github.com/izaccavalheiro/testor/releases/latest/download/setup.ps1
curl -fsSLO https://github.com/izaccavalheiro/testor/releases/latest/download/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
pwsh setup.ps1 -Tailscale && sudo tailscale up
```

Reach it as `cloud-runner` from your tailnet; keep the cloud firewall (security group) closed
to 6767. Everything in [the Tailscale scenario](home-lab-tailscale.md) applies.

## Option B: public, behind TLS

When people outside a tailnet must reach the dashboard:

1. Turn on [authentication](../features/authentication.md) **before** opening anything.
2. Make testor listen on localhost only (see
   [reverse proxy and TLS](../operations/reverse-proxy-tls.md#listen-on-localhost-only) for each OS).
3. Put a proxy with a certificate in front, for example Caddy:

   ```text title="/etc/caddy/Caddyfile"
   testor.example.com {
     reverse_proxy 127.0.0.1:6767 {
       flush_interval -1   # stream server-sent events at once
     }
   }
   ```

4. Open only 22 (SSH, preferably from your addresses) and 443 in the cloud firewall.

## Keeping costs down

A VM that runs tests only during the day can be stopped at night (a scheduled stop in the
cloud console). testor starts with the machine and catches up with its data; runs interrupted
by a stop are marked aborted.

## Caveats

- testor stores everything on the VM's disk. Snapshots, logs and artifacts disappear with the
  VM: keep the data disk if you recreate it, or back up `~/test-run/.testor`
  ([upgrade and backup](../operations/upgrade-and-backup.md)).
- For ephemeral, autoscaled runners, run [agents](../features/jobs-and-agents.md) in containers
  or Kubernetes (KEDA scales them on queued jobs) instead of a long-lived VM. Object storage for
  artifacts is on the [roadmap](../project/roadmap.md).
- Plain HTTP on the internet exposes passwords and tokens: never open 6767 itself.
