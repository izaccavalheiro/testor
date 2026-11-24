---
sidebar_position: 7
title: A spare machine over Tailscale
description: Turn an old laptop or a mini PC into an always-on runner you can reach from anywhere.
---

# A spare machine over Tailscale

**The situation.** An old laptop sits in a drawer. You want it to run your tests whether you
are at home, at the office or on a train.

## 1. Make it always on

| OS | Lid closed on AC power | After a power cut |
| -- | ---------------------- | ----------------- |
| Windows | Power Options → lid action "Do nothing" | BIOS: power on after AC loss; testor starts at boot without a login |
| Linux | `HandleLidSwitchExternalPower=ignore` in `/etc/systemd/logind.conf` | testor's user service starts at boot (lingering) |
| macOS | `sudo pmset -c sleep 0` | turn on automatic login: the launchd agent runs in the user's session |

Keep the battery: it is a free UPS, and testor shows its charge on the Device page.

## 2. Tailscale on both machines

```sh
pwsh setup.ps1 -Tailscale        # on the runner (or install it yourself), then sign in
```

Install Tailscale on the workstation too and sign in to the same tailnet. MagicDNS gives the
runner a name (`old-laptop`) that works from anywhere, and WireGuard encrypts everything,
including testor's plain HTTP. On Windows, testor's firewall rule already allows Tailscale's
range `100.64.0.0/10`.

```sshconfig title="~/.ssh/config"
Host old-laptop
  HostName old-laptop
  User me
```

## 3. Install and use

```sh
task testor:deploy               # with RUNNER: old-laptop
open http://old-laptop:6767      # from anywhere on the tailnet
```

## Optional: HTTPS inside the tailnet

`tailscale serve` gives the dashboard an HTTPS address with a valid certificate, reachable only
from your tailnet:

```sh
tailscale serve --bg 6767        # https://old-laptop.<tailnet>.ts.net
```

## Caveats

- **Thermals**: a closed laptop running builds gets hot; leave it open or on a stand. The Device
  page shows CPU load per core so you can see throttling.
- **Disk**: small SSDs fill with `node_modules` and build caches; enable
  [maintenance](../features/retention-and-maintenance.md#maintenance-everything-else-testing-leaves).
- **Updates**: Windows may reboot for updates; testor and sshd come back on their own, but a
  run in progress is aborted. Set active hours that match when you run tests.
