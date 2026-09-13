variable "namespace" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "bucket_arn" {
  type = string
}

variable "processing_queue_arn" {
  type = string
}

variable "status_queue_arn" {
  type = string
}

variable "notification_queue_arn" {
  type = string
}

variable "events_topic_arn" {
  type = string
}

locals {
  consume = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:ChangeMessageVisibility",
    "sqs:GetQueueUrl",
    "sqs:GetQueueAttributes",
  ]

  # Menor privilégio por serviço. Chave = nome do ServiceAccount (e da release Helm).
  # auth-service e gateway não acessam a AWS e não recebem role.
  policies = {
    "fiapx-video-api" = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:GetObject"]
          Resource = ["${var.bucket_arn}/raw/*", "${var.bucket_arn}/processed/*"]
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
          Resource = [var.processing_queue_arn]
        },
        {
          Effect   = "Allow"
          Action   = local.consume
          Resource = [var.status_queue_arn]
        },
      ]
    })

    "fiapx-processing-worker" = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = ["${var.bucket_arn}/raw/*"]
        },
        {
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = ["${var.bucket_arn}/processed/*"]
        },
        {
          Effect   = "Allow"
          Action   = local.consume
          Resource = [var.processing_queue_arn]
        },
        {
          # O SnsTemplate resolve o ARN pelo nome chamando CreateTopic (idempotente).
          Effect   = "Allow"
          Action   = ["sns:Publish", "sns:CreateTopic"]
          Resource = [var.events_topic_arn]
        },
      ]
    })

    "fiapx-notification-service" = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = local.consume
          Resource = [var.notification_queue_arn]
        },
        {
          Effect   = "Allow"
          Action   = ["ses:SendEmail", "ses:SendRawEmail"]
          Resource = ["*"]
        },
      ]
    })
  }
}

resource "aws_iam_policy" "service" {
  for_each = local.policies
  name     = "${each.key}-policy"
  policy   = each.value
}

module "irsa" {
  source   = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version  = "5.60.0"
  for_each = local.policies

  role_name = "${each.key}-irsa"
  role_policy_arns = {
    service = aws_iam_policy.service[each.key].arn
  }

  oidc_providers = {
    eks = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.namespace}:${each.key}"]
    }
  }
}

output "role_arns" {
  value = { for name, role in module.irsa : name => role.iam_role_arn }
}
