# FIAP X — Sistema de Processamento de Vídeos

Hackathon POSTECH SOAT — Fase 5. Este repositório (`fiapx-infra`) contém a
documentação de arquitetura, os scripts de banco, o ambiente local e, na fase 2,
o Terraform e os charts Helm.

## Repositórios

| Repositório | Papel |
|---|---|
| `fiapx-contracts` | Eventos compartilhados entre os serviços |
| `fiapx-auth-service` | Cadastro, login, JWT RS256 |
| `fiapx-video-api` | Upload, status, download |
| `fiapx-processing-worker` | ffmpeg + ZIP |
| `fiapx-notification-service` | E-mail de falha (fase 2) |
| `fiapx-gateway` | Roteamento e UI (fase 2) |
| `fiapx-infra` | Este repositório |

## Subir o ambiente local

    docker compose up --build

Sem nenhuma credencial AWS: o LocalStack provê S3, SQS e SNS.

## Testes de ponta a ponta

    docker compose up --build -d
    cd e2e && ./mvnw test

Cobrem: fluxo completo do upload ao ZIP, dois vídeos em paralelo, isolamento
entre usuários, exigência de token e recusa de formato inválido.

## Documentação

- Arquitetura: `docs/superpowers/specs/2026-09-10-fiapx-microservices-design.md`
- Planos: `docs/superpowers/plans/`
- Projeto base original: `legacy/`

## Deploy na AWS

Pré-requisitos na máquina: `aws` CLI autenticado na conta, `terraform` ≥ 1.6, `kubectl`,
`helm` 3 e Docker. No Windows:
`winget install Amazon.AWSCLI Hashicorp.Terraform Kubernetes.kubectl Helm.Helm`.

    # 1. Estado remoto (uma vez por conta)
    terraform -chdir=terraform/bootstrap init
    terraform -chdir=terraform/bootstrap apply
    terraform -chdir=terraform/bootstrap output -raw backend_config > terraform/backend.hcl

    # 2. Infraestrutura (~20 min, a maior parte é o EKS)
    cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # ajuste o e-mail
    terraform -chdir=terraform init -backend-config=backend.hcl
    terraform -chdir=terraform apply

    # 3. Confirme o link de verificação que a AWS enviou para o e-mail do SES

    # 4. Imagens e serviços
    ./scripts/deploy-eks.sh

O script imprime o endereço do load balancer: a UI fica em `http://<endereço>/`.
Enquanto a conta estiver no sandbox do SES, o e-mail de falha só chega a destinatários
verificados: para demonstrar o RF-05, cadastre-se com o mesmo e-mail do `terraform.tfvars`.

## Destruir tudo

O EKS custa cerca de US$ 0,10/h mesmo parado. Depois da gravação:

    helm uninstall -n fiapx fiapx-gateway   # remove o load balancer antes da VPC
    terraform -chdir=terraform destroy
    terraform -chdir=terraform/bootstrap destroy
