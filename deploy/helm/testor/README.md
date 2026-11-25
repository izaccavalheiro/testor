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

### Agents: running tests in the cluster

With jobs on (`execution.enabled` in config.json) and an agent user's token in a Secret:

```sh
kubectl create secret generic testor-agent --from-literal=token="$(task testor:token USER=k8s-agent DAYS=30 SCOPE=agent)"
helm upgrade testor deploy/helm/testor --reuse-values \
  --set agents.enabled=true --set agents.tokenSecret=testor-agent \
  --set agents.image.repository=registry.example.com/my-agent \
  --set agents.projects.web.repository=https://github.com/me/web.git \
  --set 'agents.projects.web.commands.test=npm ci; npm test'
```

| Value | Default | |
| ----- | ------- | - |
| `agents.enabled` | `false` | a Deployment of agent pods (`runner/agent.ps1`), sending their runs to this testor |
| `agents.image` | `ghcr.io/izaccavalheiro/testor-agent` | an image built FROM it with your projects' tools |
| `agents.tokenSecret` | | a Secret with `token`: a token of a user with the `agent` role |
| `agents.projects` | `{}` | agent.json's projects: a `repository` to clone, the `commands` jobs may run |
| `agents.env` | `[]` | more environment for the agents: `valueFrom.secretKeyRef` for secrets referenced as `env:` |
| `agents.secretMounts` | `[]` | `{secret, mountPath}`: Secrets mounted read-only, for secrets referenced as `file:` |
| `agents.vault` | `{}` | agent.json's `vault`: `address`, `kubernetesRole`, `namespace`... |
| `agents.serviceAccount` | none | `create`, `name`, `annotations` (a cloud workload identity for `aws:`, `gcp:`, `azure:`), `automountToken` (for Vault's Kubernetes login) |
| `agents.labels` | `[linux]` | jobs asking for labels go to agents that have them all |
| `agents.autoscaling.keda` | `false` | a KEDA ScaledObject on `testor_jobs` (Prometheus), from `minReplicas` (0) to `maxReplicas` |

Agent pods are separate from testor's (their own `app.kubernetes.io/name`), hardened the same
way, and admitted by testor's NetworkPolicy. Their egress (testor, your git server, package
registries) is not restricted by the chart.
