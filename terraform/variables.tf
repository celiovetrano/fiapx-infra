variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "fiapx"
}

variable "eks_version" {
  description = "Versão do Kubernetes. Use uma versão em suporte padrão: o suporte estendido custa 6x mais."
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "notification_email" {
  description = "Remetente dos e-mails de falha. Precisa ser verificado no SES (a AWS envia o link de confirmação)."
  type        = string
}
