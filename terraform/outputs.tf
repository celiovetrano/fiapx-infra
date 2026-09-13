output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "ecr_registry" {
  value = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "db_address" {
  value = module.rds.address
}

output "db_password_secret" {
  value = module.rds.password_secret_name
}

output "jwt_secret" {
  value = aws_secretsmanager_secret.jwt.name
}

output "bucket_name" {
  value = module.storage.bucket_name
}

output "notification_email" {
  value = var.notification_email
}

output "irsa_role_arns" {
  value = module.iam.role_arns
}
