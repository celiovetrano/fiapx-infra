# Mesmos nomes do LocalStack (localstack/init/01-resources.sh): os serviços não mudam
# de configuração entre o ambiente local e a AWS.

resource "aws_sqs_queue" "processing_dlq" {
  name = "video-processing-dlq"
}

resource "aws_sqs_queue" "processing" {
  name = "video-processing-queue"
  # Maior que o timeout do ffmpeg (600 s): a mensagem não reaparece no meio do processamento.
  visibility_timeout_seconds = 900
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.processing_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sns_topic" "events" {
  name = "video-events"
}

locals {
  subscribed = {
    status       = "video-status-queue"
    notification = "notification-queue"
  }
}

resource "aws_sqs_queue" "subscribed_dlq" {
  for_each = local.subscribed
  name     = "${each.value}-dlq"
}

resource "aws_sqs_queue" "subscribed" {
  for_each = local.subscribed
  name     = each.value
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.subscribed_dlq[each.key].arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_policy" "allow_sns" {
  for_each  = local.subscribed
  queue_url = aws_sqs_queue.subscribed[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.subscribed[each.key].arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.events.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "subscribed" {
  for_each             = local.subscribed
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.subscribed[each.key].arn
  raw_message_delivery = true
}

output "processing_queue_arn" {
  value = aws_sqs_queue.processing.arn
}

output "processing_dlq_arn" {
  value = aws_sqs_queue.processing_dlq.arn
}

output "status_queue_arn" {
  value = aws_sqs_queue.subscribed["status"].arn
}

output "notification_queue_arn" {
  value = aws_sqs_queue.subscribed["notification"].arn
}

output "events_topic_arn" {
  value = aws_sns_topic.events.arn
}
