---
sidebar_position: 6
title: Kubernetes with Terraform
description: Install testor in Kubernetes with the Helm chart from ghcr.io, or with one terraform apply.
---

# Kubernetes with Terraform

The Helm chart is published with every release as a signed OCI artifact:

```sh
helm install testor oci://ghcr.io/izaccavalheiro/charts/testor --version 0.13.0 \
  -n testor --create-namespace --set auth.existingSecret=testor-admin
```

Verify it first with cosign (keyless, signed by the release workflow):

```sh
cosign verify ghcr.io/izaccavalheiro/charts/testor:0.13.0 \
  --certificate-identity-regexp 'https://github.com/izaccavalheiro/testor/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## One `terraform apply`

The module in `deploy/terraform/testor` wraps that chart in a `helm_release`, with the settings
used most typed and checked before anything is applied:

```hcl
provider "helm" {
  kubernetes = { config_path = "~/.kube/config" }
}

module "testor" {
  source = "github.com/izaccavalheiro/testor//deploy/terraform/testor?ref=v0.13.0"

  namespace    = "testor"
  admin_secret = "testor-admin" # a Secret with a key "password", 12 characters or more
  persistence  = { size = "20Gi" }
}

output "url" { value = module.testor.url }
```

- **Secrets by name only.** `admin_secret`, `database_secret`, `tls_secret`,
  `agents.token_secret` name existing Kubernetes Secrets; no secret value reaches the Terraform
  state.
- **Several replicas** need `database_secret` and a ReadWriteMany volume: the module refuses
  the plan otherwise, before Helm sees it.
- **Anything else** the chart takes goes in `values`, merged last.

Three examples are in the repository, and CI checks each: [`minimal`](https://github.com/izaccavalheiro/testor/tree/main/deploy/terraform/examples/minimal),
[`cluster`](https://github.com/izaccavalheiro/testor/tree/main/deploy/terraform/examples/cluster) (three replicas, PostgreSQL, TLS, an ingress) and
[`agents-keda`](https://github.com/izaccavalheiro/testor/tree/main/deploy/terraform/examples/agents-keda) (agents scaled on queued jobs).
The [module's README](https://github.com/izaccavalheiro/testor/tree/main/deploy/terraform/testor) lists every variable.
