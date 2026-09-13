variable "repositories" {
  type = list(string)
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(var.repositories)
  name                 = each.value
  image_tag_mutability = "MUTABLE"
  # Permite o terraform destroy mesmo com imagens no repositório.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "repository_urls" {
  value = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}
