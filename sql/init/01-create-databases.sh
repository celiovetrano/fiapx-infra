#!/bin/bash
set -e
# --dbname é obrigatório: sem ele o psql tenta um banco com o nome do usuário
# ("fiapx"), que não existe, e o container sai com código 2.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE auth_db;
    CREATE DATABASE video_db;
    CREATE DATABASE notification_db;
EOSQL
echo "Bancos auth_db, video_db e notification_db criados."
