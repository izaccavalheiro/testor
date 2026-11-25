---
sidebar_position: 2
title: Reverse proxy and TLS
description: Serve testor over HTTPS with Caddy, nginx or tailscale serve, and make it listen on localhost only.
---

# Reverse proxy and TLS

testor speaks plain HTTP. That is fine over Tailscale (WireGuard encrypts it) and on a network
only you use. Anywhere else, give testor a certificate, or put a TLS-terminating proxy in front
and keep testor itself off the network.

## Listen on localhost only

Make testor listen on loopback only, so only the proxy reaches it, and tell it the proxy's
name and address. `task testor:deploy` keeps these settings on the runner across redeploys:

```sh
task testor:deploy BIND=127.0.0.1 ALLOWED_HOSTS=testor.example.com TRUSTED_PROXIES=127.0.0.1
```

(`install.ps1 -Bind -AllowedHosts -TrustedProxies` on the runner itself.)

**No proxy at all?** testor serves HTTPS itself with a certificate and its key in PEM files
(`tailscale cert`, or any ACME client): `task testor:deploy TLS_CERT=/path/cert.pem
TLS_KEY=/path/key.pem`.

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
- **The public name.** testor answers only host names it knows: add the proxy's
  (`task testor:deploy ALLOWED_HOSTS=testor.example.com`).
- **Client addresses.** Name the proxy in `TRUSTED_PROXIES` (`127.0.0.1` for one on the same
  machine): rate limiting, the audit log and the private-address check then use the client's
  address from `X-Forwarded-For`. Without it every client has the proxy's address, so one
  person's typos lock out the others, and with authentication off a local proxy makes every
  client look local.
- Event streams send a comment every 15 seconds; proxy idle timeouts shorter than that close
  them (the dashboard reconnects, but it flickers).
