terraform {
  required_version = ">= 1.5.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0, < 4.0.0"
    }
  }
}

variable "kubeconfig" {
  description = "The kubeconfig file of the cluster to install into."
  type        = string
  default     = "~/.kube/config"
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig
  }
}
