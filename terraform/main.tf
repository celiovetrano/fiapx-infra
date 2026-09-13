data "aws_caller_identity" "current" {}

locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id
  namespace  = "fiapx"
  services = [
    "fiapx-auth-service",
    "fiapx-video-api",
    "fiapx-processing-worker",
    "fiapx-notification-service",
    "fiapx-gateway",
  ]
}

module "network" {
  source = "./modules/network"
  name   = local.name
}

module "eks" {
  source             = "./modules/eks"
  name               = local.name
  kubernetes_version = var.eks_version
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.private_subnet_ids
  instance_type      = var.node_instance_type
  desired_size       = var.node_desired_size
}

module "rds" {
  source                     = "./modules/rds"
  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
  instance_class             = var.db_instance_class
}

module "storage" {
  source = "./modules/storage"
  # Nome de bucket é global na AWS: o sufixo com a conta evita colisão.
  bucket_name = "${local.name}-videos-${local.account_id}"
}

module "messaging" {
  source = "./modules/messaging"
}

module "email" {
  source             = "./modules/email"
  notification_email = var.notification_email
}

module "ecr" {
  source       = "./modules/ecr"
  repositories = local.services
}

module "iam" {
  source                 = "./modules/iam"
  namespace              = local.namespace
  oidc_provider_arn      = module.eks.oidc_provider_arn
  bucket_arn             = module.storage.bucket_arn
  processing_queue_arn   = module.messaging.processing_queue_arn
  status_queue_arn       = module.messaging.status_queue_arn
  notification_queue_arn = module.messaging.notification_queue_arn
  events_topic_arn       = module.messaging.events_topic_arn
}
