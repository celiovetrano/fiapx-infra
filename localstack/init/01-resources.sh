#!/bin/bash
set -e

BUCKET=fiapx-videos
PROCESSING_QUEUE=video-processing-queue
PROCESSING_DLQ=video-processing-dlq
STATUS_QUEUE=video-status-queue
NOTIFICATION_QUEUE=notification-queue
TOPIC=video-events

awslocal s3 mb "s3://${BUCKET}"

DLQ_URL=$(awslocal sqs create-queue --queue-name "${PROCESSING_DLQ}" --output text --query QueueUrl)
DLQ_ARN=$(awslocal sqs get-queue-attributes --queue-url "${DLQ_URL}" \
    --attribute-names QueueArn --output text --query 'Attributes.QueueArn')

awslocal sqs create-queue --queue-name "${PROCESSING_QUEUE}" --attributes "{
  \"VisibilityTimeout\": \"900\",
  \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"
}"

TOPIC_ARN=$(awslocal sns create-topic --name "${TOPIC}" --output text --query TopicArn)

# Igual ao Terraform: cada fila assinada no tópico tem a sua DLQ "<fila>-dlq", após 5 recebimentos.
for QUEUE in "${STATUS_QUEUE}" "${NOTIFICATION_QUEUE}"; do
    QUEUE_DLQ_URL=$(awslocal sqs create-queue --queue-name "${QUEUE}-dlq" --output text --query QueueUrl)
    QUEUE_DLQ_ARN=$(awslocal sqs get-queue-attributes --queue-url "${QUEUE_DLQ_URL}" \
        --attribute-names QueueArn --output text --query 'Attributes.QueueArn')
    QUEUE_URL=$(awslocal sqs create-queue --queue-name "${QUEUE}" --attributes "{
  \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"${QUEUE_DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"5\\\"}\"
}" --output text --query QueueUrl)
    QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url "${QUEUE_URL}" \
        --attribute-names QueueArn --output text --query 'Attributes.QueueArn')
    awslocal sns subscribe --topic-arn "${TOPIC_ARN}" --protocol sqs \
        --notification-endpoint "${QUEUE_ARN}" \
        --attributes RawMessageDelivery=true
done

echo "Recursos criados: bucket ${BUCKET}, filas e topico ${TOPIC}."
