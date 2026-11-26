# testor with agents that KEDA scales on queued jobs (testor_jobs{status="queued"} from
# Prometheus). Jobs must be on: execution.enabled in testor's config.json. The agents' token
# is a Secret with a key "token" (task testor:token USER=<an agent user>).

module "testor" {
  source = "../../testor"

  namespace    = "testor"
  admin_secret = "testor-admin"

  agents = {
    enabled      = true
    token_secret = "testor-agent-token"
    labels       = ["linux", "node"]
    projects = {
      web = {
        repository = "https://github.com/example/web.git"
        commands   = { test = "npm ci && npm test" }
      }
    }
    autoscaling = {
      keda              = true
      min_replicas      = 0
      max_replicas      = 10
      prometheus_server = "http://prometheus-server.monitoring.svc"
      queued_per_agent  = 2
    }
  }
}

output "url" {
  description = "testor's address inside the cluster."
  value       = module.testor.url
}
