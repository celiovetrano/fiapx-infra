-- =====================================================================
-- FIAP X - Script de criacao do banco de dados
-- Um schema por servico. Aplicado automaticamente pelo Flyway em cada
-- servico; este arquivo consolidado existe como entregavel e como
-- referencia para criacao manual.
-- =====================================================================

-- ---------- auth_db ----------
CREATE TABLE users (
    id            UUID PRIMARY KEY,
    email         VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(60)  NOT NULL,
    full_name     VARCHAR(120) NOT NULL,
    enabled       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX idx_users_email_lower ON users (LOWER(email));

-- ---------- video_db ----------
CREATE TABLE videos (
    id                UUID PRIMARY KEY,
    user_id           UUID         NOT NULL,
    user_email        VARCHAR(255) NOT NULL,
    original_filename VARCHAR(255) NOT NULL,
    size_bytes        BIGINT       NOT NULL,
    s3_raw_key        VARCHAR(512) NOT NULL,
    s3_zip_key        VARCHAR(512),
    status            VARCHAR(20)  NOT NULL,
    frame_count       INTEGER,
    error_code        VARCHAR(40),
    error_message     TEXT,
    attempts          INTEGER      NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    started_at        TIMESTAMPTZ,
    finished_at       TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_videos_user_created ON videos (user_id, created_at DESC);
CREATE INDEX idx_videos_status       ON videos (status);

CREATE TABLE video_status_history (
    id          BIGSERIAL PRIMARY KEY,
    video_id    UUID        NOT NULL REFERENCES videos (id) ON DELETE CASCADE,
    from_status VARCHAR(20),
    to_status   VARCHAR(20) NOT NULL,
    reason      TEXT,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_history_video ON video_status_history (video_id, changed_at);

-- ---------- notification_db ----------
-- Consumido pelo notification-service, que entra na fase 2. A tabela e criada
-- desde ja para que o script consolidado corresponda a arquitetura documentada.
CREATE TABLE notifications (
    id                  UUID PRIMARY KEY,
    user_id             UUID         NOT NULL,
    video_id            UUID         NOT NULL,
    channel             VARCHAR(20)  NOT NULL,
    recipient           VARCHAR(255) NOT NULL,
    subject             VARCHAR(255) NOT NULL,
    body                TEXT         NOT NULL,
    status              VARCHAR(20)  NOT NULL,
    attempts            INTEGER      NOT NULL DEFAULT 0,
    provider_message_id VARCHAR(255),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    sent_at             TIMESTAMPTZ
);
CREATE INDEX idx_notifications_video ON notifications (video_id);
