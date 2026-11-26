locals {
  agents = var.agents

  # The chart's values from the variables, in its own names. Optional pieces are left out when
  # empty so the chart's defaults stay in force.
  base_values = {
    image        = { for k, v in var.image : k => v if v != "" }
    allowedHosts = var.allowed_hosts
    replicas     = var.replicas
    auth         = { existingSecret = var.admin_secret }
    database     = { existingSecret = var.database_secret }
    tls          = merge({ existingSecret = var.tls_secret }, var.tls_acme == null ? {} : { acme = var.tls_acme })
    persistence = {
      size          = var.persistence.size
      storageClass  = var.persistence.storage_class
      accessModes   = var.persistence.access_modes
      existingClaim = var.persistence.existing_claim
    }
    ingress = {
      enabled     = var.ingress.enabled
      className   = var.ingress.class_name
      host        = var.ingress.host
      tlsSecret   = var.ingress.tls_secret
      annotations = var.ingress.annotations
    }
    networkPolicy = merge(
      { enabled = var.network_policy.enabled },
      var.network_policy.ingress_from == null ? {} : { ingressFrom = var.network_policy.ingress_from },
      var.network_policy.egress_to == null ? {} : { egressTo = var.network_policy.egress_to },
    )
    agents = {
      enabled     = local.agents.enabled
      replicas    = local.agents.replicas
      image       = { for k, v in local.agents.image : k => v if v != null && v != "" }
      tokenSecret = local.agents.token_secret
      server      = local.agents.server
      labels      = local.agents.labels
      projects    = local.agents.projects
      autoscaling = {
        keda             = local.agents.autoscaling.keda
        minReplicas      = local.agents.autoscaling.min_replicas
        maxReplicas      = local.agents.autoscaling.max_replicas
        prometheusServer = local.agents.autoscaling.prometheus_server
        queuedPerAgent   = local.agents.autoscaling.queued_per_agent
      }
    }
  }

  local_chart = var.chart_path != null
  fullname    = strcontains(var.name, "testor") ? var.name : "${var.name}-testor"
  port        = try(var.values.service.port, 6767)
  scheme      = var.tls_secret != "" || var.tls_acme != null ? "https" : "http"
}

resource "helm_release" "this" {
  name             = var.name
  namespace        = var.namespace
  create_namespace = var.create_namespace

  chart      = local.local_chart ? var.chart_path : "testor"
  repository = local.local_chart ? null : var.chart_repository
  version    = local.local_chart ? null : var.chart_version

  # Two documents: Helm merges them in order, so `values` wins over the typed variables.
  values = [yamlencode(local.base_values), yamlencode(var.values)]

  atomic          = var.atomic
  cleanup_on_fail = true
  wait            = true
  timeout         = var.timeout

  lifecycle {
    precondition {
      condition     = var.tls_secret == "" || var.tls_acme == null
      error_message = "tls_secret and tls_acme: choose one source of certificates."
    }

    precondition {
      condition     = var.replicas == 1 || var.database_secret != ""
      error_message = "replicas > 1 needs database_secret: testors share the job queue, claims and approvals through PostgreSQL."
    }

    precondition {
      condition     = var.replicas == 1 || var.persistence.existing_claim != "" || contains(var.persistence.access_modes, "ReadWriteMany")
      error_message = "replicas > 1 needs a volume every replica mounts: persistence.access_modes = [\"ReadWriteMany\"] or an existing_claim."
    }
  }
}
