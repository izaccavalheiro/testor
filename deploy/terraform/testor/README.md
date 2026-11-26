# testor's Terraform module

Installs testor in Kubernetes with one `terraform apply`: a `helm_release` of the chart
(`deploy/helm/testor`), published on every release as a signed OCI artifact at
`oci://ghcr.io/izaccavalheiro/charts/testor`.

```hcl
provider "helm" {
  kubernetes = { config_path = "~/.kube/config" }
}

module "testor" {
  source = "github.com/izaccavalheiro/testor//deploy/terraform/testor?ref=v0.13.0"

  namespace    = "testor"
  admin_secret = "testor-admin" # a Secret with a key "password"
}
```

Requirements: Terraform 1.5 or later, the `hashicorp/helm` provider 3.x.

## What it takes

| Variable | Chart value | Notes |
| -------- | ----------- | ----- |
| `name`, `namespace`, `create_namespace` | | the release |
| `chart_path` | | a local chart instead of the published one |
| `chart_repository`, `chart_version` | | the OCI chart; the version defaults to the module's own |
| `image` | `image` | `repository`, `tag` or `digest` (`sha256:...`), `pullPolicy` |
| `replicas` | `replicas` | more than one needs `database_secret` and a ReadWriteMany volume (checked before apply) |
| `allowed_hosts` | `allowedHosts` | |
| `admin_secret` | `auth.existingSecret` | |
| `database_secret` | `database.existingSecret` | |
| `tls_secret` | `tls.existingSecret` | built-in TLS from a Secret (cert-manager) |
| `persistence` | `persistence` | `size`, `storage_class`, `access_modes`, `existing_claim` |
| `ingress` | `ingress` | `enabled`, `class_name`, `host`, `tls_secret`, `annotations` |
| `network_policy` | `networkPolicy` | `enabled`, `ingress_from`, `egress_to` |
| `agents` | `agents` | `enabled`, `token_secret`, `labels`, `projects`, `autoscaling` (KEDA) |
| `values` | anything | merged last, over everything above |

Outputs: `namespace`, `service_name`, `url` (inside the cluster), `ingress_url`, `revision`,
`chart_version`.

## Secrets stay out of the state

Every secret is the **name** of an existing Kubernetes Secret, never its value, so nothing
secret lands in the Terraform state. Create the Secrets with `kubectl`, an operator (External
Secrets, Sealed Secrets) or a separate, protected Terraform configuration. CI checks that the
admin password used in its end-to-end test is not in `terraform show -json`.

## Examples

- [`examples/minimal`](../examples/minimal): one testor on a volume;
- [`examples/cluster`](../examples/cluster): three replicas, PostgreSQL, built-in TLS, an ingress;
- [`examples/agents-keda`](../examples/agents-keda): agents that KEDA scales on queued jobs.

CI runs `terraform fmt`, `init` and `validate` on each example, `tflint` and `trivy config`,
and applies `examples/minimal` on a kind cluster with the image just built
(`scripts/terraform-e2e.sh`), checks `/api/health`, and destroys it.

## Verifying the chart

```sh
cosign verify ghcr.io/izaccavalheiro/charts/testor:0.13.0 \
  --certificate-identity-regexp 'https://github.com/izaccavalheiro/testor/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
