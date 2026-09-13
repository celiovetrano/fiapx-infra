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

## Documentação

- Arquitetura: `docs/superpowers/specs/2026-09-10-fiapx-microservices-design.md`
- Planos: `docs/superpowers/plans/`
- Projeto base original: `legacy/`
