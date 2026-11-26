# The chart's most used settings, typed and checked here; `values` reaches everything else.
# Secrets are passed by the name of an existing Kubernetes Secret, never by value, so no secret
# lands in the Terraform state.

variable "name" {
  description = "The Helm release's name."
  type        = string
  default     = "testor"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,51}[a-z0-9])?$", var.name))
    error_message = "name must be a DNS label of 53 characters or fewer (lower case letters, digits and -)."
  }
}

variable "namespace" {
  description = "The Kubernetes namespace to install into."
  type        = string
  default     = "testor"
}

variable "create_namespace" {
  description = "Create the namespace when it does not exist."
  type        = bool
  default     = false
}

variable "chart_path" {
  description = "A local path to the chart (for example deploy/helm/testor in a clone). Null: the OCI chart below."
  type        = string
  default     = null
}

variable "chart_repository" {
  description = "The OCI repository of the published chart."
  type        = string
  default     = "oci://ghcr.io/izaccavalheiro/charts"
}

variable "chart_version" {
  description = "The chart's version: the module's own by default (scripts/release.mjs keeps them together)."
  type        = string
  default     = "0.14.0"
}

variable "image" {
  description = "testor's image: repository, and a tag or (preferred in production) a digest. Empty: the chart's appVersion."
  type = object({
    repository = optional(string, "ghcr.io/izaccavalheiro/testor")
    tag        = optional(string, "")
    digest     = optional(string, "")
    pullPolicy = optional(string, "IfNotPresent")
  })
  default = {}

  validation {
    condition     = var.image.digest == "" || can(regex("^sha256:[0-9a-f]{64}$", var.image.digest))
    error_message = "image.digest must be sha256:<64 hex digits>."
  }

  validation {
    condition     = contains(["IfNotPresent", "Always", "Never"], var.image.pullPolicy)
    error_message = "image.pullPolicy must be IfNotPresent, Always or Never."
  }
}

variable "replicas" {
  description = "Testors serving one team. More than one needs database_secret, and storage_s3 with keys_secret or a ReadWriteMany volume."
  type        = number
  default     = 1

  validation {
    condition     = var.replicas >= 1 && floor(var.replicas) == var.replicas
    error_message = "replicas must be a whole number, 1 or more."
  }
}

variable "allowed_hosts" {
  description = "Host names browsers and clients use (DNS rebinding protection), besides the ingress host and the service's names."
  type        = list(string)
  default     = []
}

variable "admin_secret" {
  description = "A Secret with a key \"password\" (12 characters or more): the admin user is created from it, so authentication is on from the first request."
  type        = string
  default     = ""
}

variable "database_secret" {
  description = "A Secret with a key \"url\" (postgres://...): the job queue, claims and approvals in PostgreSQL."
  type        = string
  default     = ""
}

variable "tls_secret" {
  description = "A kubernetes.io/tls Secret (tls.crt, tls.key) for testor's built-in TLS, for example from cert-manager."
  type        = string
  default     = ""
}

variable "tls_acme" {
  description = "Certificates testor orders itself from an ACME CA (tls.acme: domains, email, directory, httpPort, ...). Not with tls_secret."
  type        = any
  default     = null

  validation {
    condition     = var.tls_acme == null || can(length(var.tls_acme.domains) > 0)
    error_message = "tls_acme needs domains: the names the certificate covers."
  }
}

variable "storage_s3" {
  description = "Runs kept in an S3-compatible bucket (docs/storage.md): bucket, region, and optionally endpoint, path_style, prefix, public_endpoint, encryption, kms_key_id, presign, cache_mb, existing_secret (access-key-id, secret-access-key; else IRSA or workload identity through service_account_annotations)."
  type = object({
    bucket          = string
    region          = string
    endpoint        = optional(string, "")
    path_style      = optional(bool, false)
    prefix          = optional(string, "")
    public_endpoint = optional(string, "")
    encryption      = optional(string, "")
    kms_key_id      = optional(string, "")
    presign         = optional(bool, true)
    cache_mb        = optional(number, 2048)
    existing_secret = optional(string, "")
  })
  default = null

  validation {
    condition     = var.storage_s3 == null || contains(["", "AES256", "aws:kms"], try(var.storage_s3.encryption, ""))
    error_message = "storage_s3.encryption is AES256 or aws:kms."
  }
}

variable "keys_secret" {
  description = "A Secret with token-key, signing-key (base64 Ed25519 seeds) and jwt-secret: one set of keys for replicas that share no volume."
  type        = string
  default     = ""
}

variable "service_account_annotations" {
  description = "Annotations of testor's service account: an IAM role (eks.amazonaws.com/role-arn) or workload identity for the bucket."
  type        = map(string)
  default     = {}
}

variable "persistence" {
  description = "testor's home volume; enabled = false makes it an emptyDir (a cache of the bucket), only with storage_s3."
  type = object({
    enabled        = optional(bool, true)
    size           = optional(string, "10Gi")
    storage_class  = optional(string, "")
    access_modes   = optional(list(string), ["ReadWriteOnce"])
    existing_claim = optional(string, "")
  })
  default = {}

  validation {
    condition     = alltrue([for m in var.persistence.access_modes : contains(["ReadWriteOnce", "ReadWriteMany", "ReadWriteOncePod", "ReadOnlyMany"], m)])
    error_message = "persistence.access_modes holds Kubernetes access modes (ReadWriteOnce, ReadWriteMany...)."
  }
}

variable "ingress" {
  description = "An Ingress in front of testor."
  type = object({
    enabled     = optional(bool, false)
    class_name  = optional(string, "")
    host        = optional(string, "testor.example.com")
    tls_secret  = optional(string, "")
    annotations = optional(map(string), {})
  })
  default = {}
}

variable "network_policy" {
  description = "The NetworkPolicy around testor's pods; ingress_from and egress_to are Kubernetes peers, as in the chart."
  type = object({
    enabled      = optional(bool, true)
    ingress_from = optional(any)
    egress_to    = optional(any)
  })
  default = {}
}

variable "agents" {
  description = "Agents (the testor-agent image) that take jobs from this testor. Jobs must be on (execution.enabled in config.json)."
  type = object({
    enabled      = optional(bool, false)
    replicas     = optional(number, 1)
    image        = optional(object({ repository = optional(string), tag = optional(string), digest = optional(string) }), {})
    token_secret = optional(string, "")
    server       = optional(string, "")
    labels       = optional(list(string), ["linux"])
    # agent.json's projects, as in the chart: { my-app = { repository = "...", commands = { test = "..." } } }
    projects = optional(any, {})
    autoscaling = optional(object({
      keda              = optional(bool, false)
      min_replicas      = optional(number, 0)
      max_replicas      = optional(number, 5)
      prometheus_server = optional(string, "http://prometheus-server.monitoring.svc")
      queued_per_agent  = optional(number, 1)
    }), {})
    # Warm agents: a StatefulSet with a volume per pod (workspaces and caches survive restarts).
    persistence = optional(object({
      enabled       = optional(bool, false)
      size          = optional(string, "20Gi")
      storage_class = optional(string, "")
    }), {})
  })
  default = {}

  validation {
    condition     = !var.agents.enabled || var.agents.token_secret != ""
    error_message = "agents.token_secret (a Secret with a key \"token\" of an agent user) is needed when agents are enabled."
  }

  validation {
    condition     = var.agents.autoscaling.min_replicas <= var.agents.autoscaling.max_replicas
    error_message = "agents.autoscaling.min_replicas must not exceed max_replicas."
  }
}

variable "values" {
  description = "Any other chart values, merged last (over everything above)."
  type        = any
  default     = {}
}

variable "timeout" {
  description = "Seconds Helm waits for the release's resources to be ready."
  type        = number
  default     = 300
}

variable "atomic" {
  description = "Roll back a failed install or upgrade."
  type        = bool
  default     = true
}
