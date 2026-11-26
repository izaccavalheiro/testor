terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # 3.x: the plugin-framework provider (values as documents, metadata as an object).
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0, < 4.0.0"
    }
  }
}
