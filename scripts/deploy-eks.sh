#!/usr/bin/env bash
# Publica as cinco imagens no ECR e instala os serviços no EKS.
#
# Pré-requisitos: aws CLI autenticado, kubectl, helm, docker e o terraform/ já aplicado.
# Uso (na raiz do fiapx-infra, com os repositórios de serviço em services/):
#   ./scripts/deploy-eks.sh             # tag = data e hora
#   TAG=v1 ./scripts/deploy-eks.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
SERVICES_DIR="$ROOT/services"
CHART="$ROOT/helm/fiapx-service"
NAMESPACE=fiapx
TAG="${TAG:-$(date +%Y%m%d%H%M%S)}"

tf_out() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

secret_value() {
  aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" \
    --query SecretString --output text
}

role_arn() {
  aws iam get-role --role-name "$1-irsa" --query Role.Arn --output text
}

REGION="$(tf_out region)"
CLUSTER="$(tf_out cluster_name)"
REGISTRY="$(tf_out ecr_registry)"
DB_HOST="$(tf_out db_address)"
BUCKET="$(tf_out bucket_name)"
FROM_EMAIL="$(tf_out notification_email)"
DB_PASSWORD="$(secret_value "$(tf_out db_password_secret)")"
JWT_PEM="$(secret_value "$(tf_out jwt_secret)")"

echo ">> kubeconfig do cluster $CLUSTER"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo ">> login no ECR"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

build_and_push() {
  local service="$1" context="$2"
  local image="$REGISTRY/$service:$TAG"
  echo ">> imagem $image"
  docker build -f "$SERVICES_DIR/$service/Dockerfile" -t "$image" "$context"
  docker push "$image"
}

build_and_push fiapx-auth-service "$SERVICES_DIR/fiapx-auth-service"
build_and_push fiapx-video-api "$SERVICES_DIR"
build_and_push fiapx-processing-worker "$SERVICES_DIR"
build_and_push fiapx-notification-service "$SERVICES_DIR"
build_and_push fiapx-gateway "$SERVICES_DIR/fiapx-gateway"

echo ">> namespace e segredos"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create secret generic fiapx-db \
  --from-literal=password="$DB_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create secret generic fiapx-jwt \
  --from-literal=private-key="$JWT_PEM" --dry-run=client -o yaml | kubectl apply -f -

echo ">> bancos auth_db, video_db e notification_db"
kubectl -n "$NAMESPACE" delete pod fiapx-create-dbs --ignore-not-found
kubectl -n "$NAMESPACE" run fiapx-create-dbs --rm -i --restart=Never \
  --image=postgres:16-alpine --env="PGPASSWORD=$DB_PASSWORD" -- \
  psql -h "$DB_HOST" -U fiapx -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'CREATE DATABASE auth_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'auth_db')\gexec
SELECT 'CREATE DATABASE video_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'video_db')\gexec
SELECT 'CREATE DATABASE notification_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'notification_db')\gexec
SQL

deploy() {
  local service="$1"
  shift
  echo ">> helm $service"
  helm upgrade --install "$service" "$CHART" \
    --namespace "$NAMESPACE" \
    -f "$ROOT/helm/values/$service.yaml" \
    --set image.repository="$REGISTRY/$service" \
    --set image.tag="$TAG" \
    "$@" \
    --wait --timeout 10m
}

deploy fiapx-auth-service \
  --set env.DB_URL="jdbc:postgresql://$DB_HOST:5432/auth_db"
deploy fiapx-video-api \
  --set env.DB_URL="jdbc:postgresql://$DB_HOST:5432/video_db" \
  --set env.S3_BUCKET="$BUCKET" \
  --set serviceAccount.roleArn="$(role_arn fiapx-video-api)"
deploy fiapx-processing-worker \
  --set env.S3_BUCKET="$BUCKET" \
  --set serviceAccount.roleArn="$(role_arn fiapx-processing-worker)"
deploy fiapx-notification-service \
  --set env.DB_URL="jdbc:postgresql://$DB_HOST:5432/notification_db" \
  --set env.NOTIFICATION_FROM="$FROM_EMAIL" \
  --set serviceAccount.roleArn="$(role_arn fiapx-notification-service)"
deploy fiapx-gateway

echo ">> endereço público do gateway (o DNS do load balancer leva 1-3 min para propagar):"
kubectl -n "$NAMESPACE" get svc fiapx-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
echo
