variable "notification_email" {
  type = string
}

# Cria a identidade e dispara o e-mail de verificação da AWS. Enquanto a conta estiver
# no sandbox do SES, só é possível enviar para endereços também verificados.
resource "aws_ses_email_identity" "sender" {
  email = var.notification_email
}

output "identity_arn" {
  value = aws_ses_email_identity.sender.arn
}
