terraform {
  required_version = ">= 1.6"

  required_providers {
    # O módulo eks 20.x exige o provider AWS >= 5.95 e < 6.0.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Configurado no init: terraform init -backend-config=backend.hcl
  backend "s3" {}
}
