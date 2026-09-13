provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "fiapx"
      ManagedBy = "terraform"
    }
  }
}
