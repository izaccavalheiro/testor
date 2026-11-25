# testor Helm chart

testor's orchestrator (dashboard, `/api/v1`, MCP, `/metrics`) on Kubernetes, over a testor
home on a persistent volume. One replica, replaced on upgrade: the state is files on that
volume.

```sh
kubectl create secret generic testor-admin --from-literal=password="$TESTOR_PASSWORD"
helm install testor deploy/helm/testor \
  --set auth.existingSecret=testor-admin \
  --set ingress.enabled=true --set ingress.host=testor.example.com --set ingress.tlsSecret=testor-web \
  --set 'trustedProxies={10.0.0.0/8}'
```

| Value | Default | |
| ----- | ------- | - |
| `auth.existingSecret` | | a Secret with `password`: the `admin` user is created from it at every start |
| `allowedHosts` | | names besides the ingress host and the service's cluster names |
| `trustedProxies` | | the ingress controller's addresses, so testor sees clients |
| `anonymous` | `loopback` | who is answered while no user exists |
| `tls.existingSecret` | | a `kubernetes.io/tls` Secret: testor serves HTTPS itself |
| `networkPolicy.enabled` | `true` | ingress from `networkPolicy.ingressFrom` only; egress DNS and `networkPolicy.egressTo` (webhooks) |
| `serviceMonitor.enabled` | `false` | Prometheus Operator scraping `/metrics` with the token in `serviceMonitor.tokenSecret` |
| `persistence.size` | `10Gi` | the volume is kept on uninstall (`helm.sh/resource-policy: keep`) |

The pod runs as uid 10001, non-root, read-only root file system, no capabilities, seccomp
`RuntimeDefault`, without a service account token.

What it does not do yet: run tests in the cluster. Runs reach this testor through its
volume; a runner agent that takes work from it is designed in
[docs/design/agent-protocol.md](../../../docs/design/agent-protocol.md).
