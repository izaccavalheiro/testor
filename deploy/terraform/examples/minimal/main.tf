# One testor on a volume, with the admin user from an existing Secret:
#
#   kubectl create namespace testor
#   kubectl -n testor create secret generic testor-admin --from-literal=password='<12+ characters>'
#   terraform init && terraform apply
#   kubectl -n testor port-forward svc/testor 6767   # then http://localhost:6767

variable "chart_path" {
  description = "A local chart (deploy/helm/testor in a clone) instead of the published one."
  type        = string
  default     = null
}

variable "image" {
  description = "testor's image (tag or digest): the chart's appVersion when empty."
  type = object({
    repository = optional(string, "ghcr.io/izaccavalheiro/testor")
    tag        = optional(string, "")
    digest     = optional(string, "")
    pullPolicy = optional(string, "IfNotPresent")
  })
  default = {}
}

variable "admin_secret" {
  description = "A Secret with a key \"password\": the admin user."
  type        = string
  default     = "testor-admin"
}

module "testor" {
  source = "../../testor"

  namespace    = "testor"
  chart_path   = var.chart_path
  image        = var.image
  admin_secret = var.admin_secret
  persistence  = { size = "5Gi" }
}

output "url" {
  description = "testor's address inside the cluster."
  value       = module.testor.url
}

output "service_name" {
  description = "testor's Service."
  value       = module.testor.service_name
}
