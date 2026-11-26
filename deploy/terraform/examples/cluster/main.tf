# Three testors serving one team: one home on a ReadWriteMany volume, one PostgreSQL (the job
# queue, claims and approvals), the built-in TLS from a cert-manager Secret, and an ingress.
# Every secret is referenced by name: create them first (kubectl or your secret operator).

module "testor" {
  source = "../../testor"

  namespace        = "testor"
  create_namespace = true
  replicas         = 3

  # Prefer a digest in production: digest = "sha256:<the index digest of the release>".
  image = { tag = "0.13.0" }

  admin_secret    = "testor-admin"
  database_secret = "testor-database"
  tls_secret      = "testor-tls"

  persistence = {
    size          = "50Gi"
    storage_class = "efs"
    access_modes  = ["ReadWriteMany"]
  }

  ingress = {
    enabled    = true
    class_name = "nginx"
    host       = "testor.example.com"
    tls_secret = "testor-ingress-tls"
    annotations = {
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
    }
  }

  # Anything else the chart takes, merged last.
  values = {
    trustedProxies = ["10.0.0.0/8"]
    serviceMonitor = { enabled = true, tokenSecret = "testor-metrics" }
  }
}

output "ingress_url" {
  description = "testor's address through the ingress."
  value       = module.testor.ingress_url
}
