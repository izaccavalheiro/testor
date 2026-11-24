---
sidebar_position: 2
title: Reverse proxy and TLS
description: Serve testor over HTTPS with Caddy, nginx or tailscale serve, and make it listen on localhost only.
---

# Reverse proxy and TLS

testor speaks plain HTTP. That is fine over Tailscale (WireGuard encrypts it) and on a network
only you use. Anywhere else, put a TLS-terminating proxy in front and keep testor itself off the
network.

## Listen on localhost only

Set `TESTOR_BIND=127.0.0.1` for the service. The installer does not take this option yet (it is
planned for 0.3), so set it where the service reads its environment, in a way a redeploy
keeps:

**Linux (systemd).** A drop-in survives redeploys, which rewrite the unit itself:

```sh
mkdir -p ~/.config/systemd/user/testor.service.d
printf '[Service]\nEnvironment=TESTOR_BIND=127.0.0.1\n' > ~/.config/systemd/user/testor.service.d/bind.conf
systemctl --user daemon-reload && systemctl --user restart testor
```

**Windows.** The scheduled task's process inherits the user's environment variables:

```powershell
[Environment]::SetEnvironmentVariable("TESTOR_BIND", "127.0.0.1", "User")
Stop-ScheduledTask Testor; Start-ScheduledTask Testor
```

**macOS.** The launchd agent's plist is rewritten on each deploy. Rely on the macOS firewall,
or on the proxy running on another machine that reaches testor over Tailscale.

Check with `task testor:status`: health answers from the runner itself, and no longer from the
workstation.

## Caddy

Automatic certificates from Let's Encrypt:

```text title="/etc/caddy/Caddyfile"
testor.example.com {
  reverse_proxy 127.0.0.1:6767 {
    flush_interval -1
  }
}
```

`flush_interval -1` sends server-sent events at once instead of buffering them.

## nginx

```nginx
server {
  listen 443 ssl http2;
  server_name testor.example.com;
  ssl_certificate     /etc/letsencrypt/live/testor.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/testor.example.com/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:6767;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_buffering off;          # server-sent events
    proxy_read_timeout 1h;        # long-lived event streams
  }
}
```

## tailscale serve

Inside a tailnet, with a certificate for the machine's `ts.net` name:

```sh
tailscale serve --bg 6767
```

## Things to know behind a proxy

- **Origin checks.** State-changing requests are refused when their `Origin` is not the server.
  Keep the `Host` header the browser used (Caddy does by default; nginx with
  `proxy_set_header Host $host`).
- **Rate limiting** counts failed logins per connection address; testor does not read
  `X-Forwarded-For`. Behind a proxy every client shares the proxy's address, so one person's
  typos can lock out others for 15 minutes.
- **Audit lines** name the connection address too, which is the proxy's: keep the proxy's own
  access log for the real client addresses.
- Event streams send a comment every 15 seconds; proxy idle timeouts shorter than that close
  them (the dashboard reconnects, but it flickers).
