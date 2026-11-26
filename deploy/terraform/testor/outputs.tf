output "namespace" {
  description = "The namespace testor runs in."
  value       = helm_release.this.namespace
}

output "service_name" {
  description = "testor's Service."
  value       = local.fullname
}

output "url" {
  description = "testor's address inside the cluster (the ingress host from outside, when enabled)."
  value       = "${local.scheme}://${local.fullname}.${helm_release.this.namespace}.svc:${local.port}"
}

output "ingress_url" {
  description = "testor's address through the ingress, or null."
  value       = var.ingress.enabled ? "https://${var.ingress.host}" : null
}

output "revision" {
  description = "The Helm release's revision."
  value       = helm_release.this.metadata.revision
}

output "chart_version" {
  description = "The chart version installed."
  value       = helm_release.this.metadata.version
}
