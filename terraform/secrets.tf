# Chave RSA do JWT: todas as réplicas do auth-service assinam com a mesma chave.
resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_secretsmanager_secret" "jwt" {
  name = "${local.name}/jwt-private-key"
  # 0 = apaga na hora no destroy, para o próximo apply poder recriar com o mesmo nome.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id = aws_secretsmanager_secret.jwt.id
  # O RsaKeyProvider do auth-service lê PEM PKCS#8 ("BEGIN PRIVATE KEY").
  secret_string = tls_private_key.jwt.private_key_pem_pkcs8
}
