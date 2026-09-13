# FIAP X — Fase 2: Completar o sistema e subir na AWS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Completar os cinco serviços (notification-service e gateway com UI), colocar CI com gate de cobertura e Trivy nos sete repositórios e subir o sistema inteiro no EKS com Terraform e um chart Helm genérico.

**Architecture:** O `notification-service` consome a `notification-queue` (assinada no tópico SNS `video-events`), filtra `VideoFailed` e envia e-mail por um port `EmailSender` com dois adapters: SMTP (Mailpit no Compose) e SES (AWS). O `fiapx-gateway` (Spring Cloud Gateway, WebFlux) roteia `/api/v1/auth/**` e `/api/v1/videos/**`, valida o JWT, limita tentativas de login e serve a UI estática. Um workflow reutilizável no `fiapx-infra` faz build, testes, JaCoCo, imagem e Trivy para todos os repositórios. Na AWS, Terraform cria VPC, EKS, RDS, S3, SQS/SNS, SES, ECR e roles IRSA; um script publica as imagens e instala os serviços com Helm.

**Tech Stack:** Java 21 · Spring Boot 3.3.5 · Maven (wrapper) · Spring Cloud 2023.0.6 (Gateway) · Spring Cloud AWS 3.2.1 · AWS SDK v2 (SES v1 API, STS) · Spring Boot Mail · PostgreSQL 16 + Flyway · Testcontainers 1.21.4 (PostgreSQL, LocalStack 3.8, Mailpit v1.31.1) · OkHttp MockWebServer · GitHub Actions (checkout@v7, setup-java@v6, upload-artifact@v7, trivy-action@0.36.0) · Terraform ≥ 1.6 (AWS provider ~> 5.95, módulos vpc 5.21.0, eks 20.37.2, iam 5.60.0) · EKS 1.35 · Helm 3.

**Spec:** `docs/superpowers/specs/2026-09-10-fiapx-microservices-design.md` (seções 4, 9, 13, 14, 15, 17 e 19). Plano anterior: `docs/superpowers/plans/2026-09-10-fase1-fatia-vertical.md`.

## Global Constraints

Valem para **todas** as tarefas, somadas às restrições globais do Plano 1 (Clean Architecture, JaCoCo 80% em `domain`/`application`, RFC 7807, 404 em vez de 403, commits em Conventional Commits em português sem acento na primeira linha).

- **Java 21**, **Spring Boot 3.3.5** (`spring-boot-starter-parent`), **Maven** só pelo wrapper (`./mvnw`). Não há `mvn` no PATH da máquina de desenvolvimento.
- **Testcontainers 1.21.4** em todo `pom.xml` (`<testcontainers.version>`): versões anteriores não conversam com o Docker Engine 29.
- **Spring Cloud 2023.0.6** no gateway. A linha 2024.0 exige Boot 3.4.
- Todo teste de integração com `@SpringBootTest` num serviço que tem `@SqsListener` importa o `LocalStackTestContainer`. Sem ele o listener tenta a AWS real e o contexto não sobe.
- O `LocalStackTestContainer` publica endpoint, região, credenciais e `path-style` como propriedades `spring.cloud.aws.*` via `DynamicPropertyRegistry`. **Nunca** `@ServiceConnection` para o LocalStack.
- O spring-cloud-aws autoconfigura **só** o `SqsAsyncClient` (chamadas terminam em `.join()`). O `SnsClient` é síncrono.
- JSON para `SqsTemplate.send` é serializado **antes** do lambda (`writeValueAsString` lança exceção checada).
- Credenciais AWS: `spring.cloud.aws.credentials.access-key: ${AWS_ACCESS_KEY_ID:}` (padrão **vazio**). Vazio faz o spring-cloud-aws usar a cadeia padrão do SDK, que no EKS resolve IRSA. Todo serviço que fala com a AWS tem `software.amazon.awssdk:sts` em runtime, sem o qual o IRSA não funciona.
- Nenhum bean monta credenciais a partir de `@Value`: use os beans `AwsCredentialsProvider` e `AwsRegionProvider` do spring-cloud-aws.
- Git: todo repositório usa `git config user.email "149624872+celiovetrano@users.noreply.github.com"` (configurado por repositório). A conta do GitHub recusa push que exponha o e-mail pessoal (GH007).
- O `mvnw` é registrado como executável no git (`git update-index --chmod=+x mvnw`). O Windows grava `100644` e o `./mvnw` falha no runner Linux do CI.
- ffmpeg na máquina de desenvolvimento: `export PATH="$(cygpath -u "$HOME")/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe/ffmpeg-9.0.1-full_build/bin:$PATH"` antes de testar o worker.
- Novos serviços: `fiapx-notification-service` (porta **8084**, só actuator) e `fiapx-gateway` (porta **8080**). Mailpit: SMTP **1025**, UI/API **8025**.
- Pacotes: `br.com.fiapx.notification`, `br.com.fiapx.gateway`.
- Nomes de recursos AWS idênticos ao LocalStack, exceto o bucket: `fiapx-videos-<account_id>` na AWS (nome de bucket é global), injetado via `S3_BUCKET`.
- EKS **1.35** (a 1.33 saiu do suporte padrão em 29/07/2026; suporte estendido custa 6x) e node group **AL2023** (não há AMI AL2 a partir da 1.33).
- O `fiapx-contracts` chega ao CI por **checkout do repositório público** e `./mvnw install`, não pelo GitHub Packages (evita autenticação de pacote em cada workflow).

## Estrutura de arquivos

```
projeto-fiapx/                                   ← repo fiapx-infra
├── .github/workflows/
│   ├── maven-service.yml                        ← workflow reutilizável (Task 10)
│   ├── e2e.yml                                  ← Compose + E2E direto e via gateway (Task 10)
│   └── terraform.yml                            ← fmt + validate (Task 12)
├── docker-compose.yml                           ← + mailpit, notification-service, gateway
├── e2e/                                         ← + teste de e-mail de falha
├── terraform/                                   ← Task 12
│   ├── bootstrap/main.tf
│   ├── versions.tf providers.tf variables.tf main.tf secrets.tf outputs.tf
│   ├── terraform.tfvars.example
│   └── modules/{network,eks,rds,storage,messaging,email,ecr,iam}/main.tf
├── helm/                                        ← Task 13
│   ├── fiapx-service/ (Chart.yaml, values.yaml, templates/)
│   └── values/<serviço>.yaml
├── scripts/deploy-eks.sh                        ← Task 14
└── services/
    ├── fiapx-notification-service/              ← Tasks 1-6 (repo novo)
    └── fiapx-gateway/                           ← Tasks 7-9 (repo novo)
```

`fiapx-notification-service`:
```
src/main/java/br/com/fiapx/notification/
├── NotificationServiceApplication.java
├── domain/            Notification, NotificationStatus, FailureEmail
├── application/
│   ├── exception/     EmailDeliveryException
│   ├── port/out/      NotificationRepository, EmailSender
│   └── usecase/       NotifyVideoFailureUseCase
└── infrastructure/
    ├── config/        SesConfig
    ├── email/         SmtpEmailSender, SesEmailSender
    ├── messaging/     NotificationListener
    └── persistence/   NotificationEntity, SpringDataNotificationRepository, JpaNotificationRepository
```

`fiapx-gateway`:
```
src/main/java/br/com/fiapx/gateway/
├── GatewayApplication.java
├── config/            SecurityConfig
└── ratelimit/         FixedWindowRateLimiter, LoginRateLimitFilter
src/main/resources/static/   index.html, app.js, styles.css
```

---

## Parte A — notification-service (D4, manhã)

### Task 1: `notification-service` — repositório, pom e domínio

**Files:**
- Create: `services/fiapx-notification-service/pom.xml`
- Create: `src/main/java/br/com/fiapx/notification/NotificationServiceApplication.java`
- Create: `src/main/java/br/com/fiapx/notification/domain/{NotificationStatus,Notification,FailureEmail}.java`
- Test: `src/test/java/br/com/fiapx/notification/domain/{NotificationTest,FailureEmailTest}.java`

**Interfaces:**
- Consumes: `ErrorCode` de `br.com.fiapx.contracts` (Plano 1, Task 2).
- Produces:
  - `NotificationStatus` — `PENDING`, `SENT`, `FAILED`
  - `Notification.create(UUID userId, UUID videoId, String recipient, String subject, String body)` → `Notification` em `PENDING`
  - `Notification.rehydrate(UUID id, UUID userId, UUID videoId, String recipient, String subject, String body, NotificationStatus status, int attempts, String providerMessageId, Instant createdAt, Instant sentAt)`
  - `void markSent(String providerMessageId)`, `void markFailed()`, `boolean isSent()`, `String channel()` (= `"EMAIL"`)
  - Acessores: `id()`, `userId()`, `videoId()`, `recipient()`, `subject()`, `body()`, `status()`, `attempts()`, `providerMessageId()`, `createdAt()`, `sentAt()`
  - `FailureEmail.of(UUID videoId, ErrorCode errorCode, String technicalMessage)` → `FailureEmail(String subject, String body)`; constante `FailureEmail.SUBJECT`

- [ ] **Step 1: Criar o repositório com o Maven wrapper**

```bash
cd services && mkdir -p fiapx-notification-service && cd fiapx-notification-service
git init -b main
git config user.email "149624872+celiovetrano@users.noreply.github.com"
cp -r ../fiapx-contracts/mvnw ../fiapx-contracts/mvnw.cmd ../fiapx-contracts/.mvn \
      ../fiapx-contracts/.gitattributes ../fiapx-contracts/.gitignore .
```

- [ ] **Step 2: Escrever o `pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>3.3.5</version>
        <relativePath/>
    </parent>

    <groupId>br.com.fiapx</groupId>
    <artifactId>fiapx-notification-service</artifactId>
    <version>1.0.0</version>

    <properties>
        <java.version>21</java.version>
        <!-- 1.21.4+: versões anteriores usam uma API do Docker recusada pelo Engine 29 -->
        <testcontainers.version>1.21.4</testcontainers.version>
        <spring-cloud-aws.version>3.2.1</spring-cloud-aws.version>
    </properties>

    <dependencyManagement>
        <dependencies>
            <dependency>
                <groupId>io.awspring.cloud</groupId>
                <artifactId>spring-cloud-aws-dependencies</artifactId>
                <version>${spring-cloud-aws.version}</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
        </dependencies>
    </dependencyManagement>

    <dependencies>
        <dependency>
            <groupId>br.com.fiapx</groupId>
            <artifactId>fiapx-contracts</artifactId>
            <version>1.0.0</version>
        </dependency>

        <!-- Web só para expor /actuator na porta 8084 (probes e Prometheus). -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-actuator</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-data-jpa</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-mail</artifactId>
        </dependency>
        <dependency>
            <groupId>org.flywaydb</groupId>
            <artifactId>flyway-core</artifactId>
        </dependency>
        <dependency>
            <groupId>org.flywaydb</groupId>
            <artifactId>flyway-database-postgresql</artifactId>
        </dependency>
        <dependency>
            <groupId>io.awspring.cloud</groupId>
            <artifactId>spring-cloud-aws-starter-sqs</artifactId>
        </dependency>
        <dependency>
            <groupId>software.amazon.awssdk</groupId>
            <artifactId>ses</artifactId>
        </dependency>
        <!-- Sem o STS no classpath a cadeia padrão do SDK não resolve IRSA no EKS. -->
        <dependency>
            <groupId>software.amazon.awssdk</groupId>
            <artifactId>sts</artifactId>
            <scope>runtime</scope>
        </dependency>
        <dependency>
            <groupId>org.postgresql</groupId>
            <artifactId>postgresql</artifactId>
            <scope>runtime</scope>
        </dependency>
        <dependency>
            <groupId>io.micrometer</groupId>
            <artifactId>micrometer-registry-prometheus</artifactId>
            <scope>runtime</scope>
        </dependency>

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.testcontainers</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.testcontainers</groupId>
            <artifactId>postgresql</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.testcontainers</groupId>
            <artifactId>localstack</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-testcontainers</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.awaitility</groupId>
            <artifactId>awaitility</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-surefire-plugin</artifactId>
                <configuration>
                    <includes>
                        <include>**/*Test.java</include>
                        <include>**/*IT.java</include>
                    </includes>
                </configuration>
            </plugin>
            <plugin>
                <groupId>org.jacoco</groupId>
                <artifactId>jacoco-maven-plugin</artifactId>
                <version>0.8.12</version>
                <executions>
                    <execution>
                        <id>prepare-agent</id>
                        <goals><goal>prepare-agent</goal></goals>
                    </execution>
                    <execution>
                        <id>report</id>
                        <phase>test</phase>
                        <goals><goal>report</goal></goals>
                    </execution>
                    <execution>
                        <id>check</id>
                        <goals><goal>check</goal></goals>
                        <configuration>
                            <rules>
                                <rule>
                                    <element>PACKAGE</element>
                                    <includes>
                                        <include>br.com.fiapx.notification.domain*</include>
                                        <include>br.com.fiapx.notification.application*</include>
                                    </includes>
                                    <limits>
                                        <limit>
                                            <counter>LINE</counter>
                                            <value>COVEREDRATIO</value>
                                            <minimum>0.80</minimum>
                                        </limit>
                                    </limits>
                                </rule>
                            </rules>
                        </configuration>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 3: Escrever os testes de domínio (falham)**

`src/test/java/br/com/fiapx/notification/domain/NotificationTest.java`:
```java
package br.com.fiapx.notification.domain;

import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class NotificationTest {

    private Notification nova() {
        return Notification.create(UUID.randomUUID(), UUID.randomUUID(),
                "aluno@fiap.com.br", "assunto", "corpo");
    }

    @Test
    void nasceEmPendingSemTentativas() {
        var notificacao = nova();

        assertThat(notificacao.id()).isNotNull();
        assertThat(notificacao.status()).isEqualTo(NotificationStatus.PENDING);
        assertThat(notificacao.attempts()).isZero();
        assertThat(notificacao.channel()).isEqualTo("EMAIL");
        assertThat(notificacao.sentAt()).isNull();
        assertThat(notificacao.isSent()).isFalse();
    }

    @Test
    void markSentGuardaIdDoProvedorEHorario() {
        var notificacao = nova();

        notificacao.markSent("msg-1");

        assertThat(notificacao.status()).isEqualTo(NotificationStatus.SENT);
        assertThat(notificacao.providerMessageId()).isEqualTo("msg-1");
        assertThat(notificacao.sentAt()).isNotNull();
        assertThat(notificacao.attempts()).isEqualTo(1);
        assertThat(notificacao.isSent()).isTrue();
    }

    @Test
    void markFailedContaATentativa() {
        var notificacao = nova();

        notificacao.markFailed();

        assertThat(notificacao.status()).isEqualTo(NotificationStatus.FAILED);
        assertThat(notificacao.attempts()).isEqualTo(1);
        assertThat(notificacao.isSent()).isFalse();
    }

    @Test
    void podeSerEnviadaDepoisDeFalhar() {
        var notificacao = nova();
        notificacao.markFailed();

        notificacao.markSent("msg-2");

        assertThat(notificacao.status()).isEqualTo(NotificationStatus.SENT);
        assertThat(notificacao.attempts()).isEqualTo(2);
    }

    @Test
    void naoEnviaDuasVezes() {
        var notificacao = nova();
        notificacao.markSent("msg-1");

        assertThatThrownBy(() -> notificacao.markSent("msg-2"))
                .isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(notificacao::markFailed)
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void exigeDestinatario() {
        assertThatThrownBy(() -> Notification.create(UUID.randomUUID(), UUID.randomUUID(),
                " ", "assunto", "corpo"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
```

`src/test/java/br/com/fiapx/notification/domain/FailureEmailTest.java`:
```java
package br.com.fiapx.notification.domain;

import br.com.fiapx.contracts.ErrorCode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class FailureEmailTest {

    @ParameterizedTest
    @EnumSource(ErrorCode.class)
    void todoErrorCodeTemUmMotivoLegivel(ErrorCode codigo) {
        assertThat(FailureEmail.motivo(codigo)).isNotBlank();
    }

    @Test
    void corpoTrazIdDoVideoCodigoEDetalhe() {
        UUID videoId = UUID.randomUUID();

        var email = FailureEmail.of(videoId, ErrorCode.FFMPEG_FAILURE, "ffmpeg retornou codigo 183");

        assertThat(email.subject()).isEqualTo(FailureEmail.SUBJECT);
        assertThat(email.body())
                .contains(videoId.toString())
                .contains("FFMPEG_FAILURE")
                .contains("ffmpeg retornou codigo 183")
                .contains("corrompido");
    }

    @Test
    void toleraCodigoEMensagemNulos() {
        var email = FailureEmail.of(UUID.randomUUID(), null, null);

        assertThat(email.body()).contains("UNKNOWN").contains("sem detalhes");
    }
}
```

- [ ] **Step 4: Rodar e confirmar que falham**

Run: `./mvnw test`
Expected: FAIL na compilação — `Notification`, `NotificationStatus` e `FailureEmail` não existem.

- [ ] **Step 5: Implementar o domínio**

`domain/NotificationStatus.java`:
```java
package br.com.fiapx.notification.domain;

public enum NotificationStatus {
    PENDING,
    SENT,
    FAILED
}
```

`domain/Notification.java`:
```java
package br.com.fiapx.notification.domain;

import java.time.Instant;
import java.util.Objects;
import java.util.UUID;

public final class Notification {

    public static final String CHANNEL_EMAIL = "EMAIL";

    private final UUID id;
    private final UUID userId;
    private final UUID videoId;
    private final String recipient;
    private final String subject;
    private final String body;
    private final Instant createdAt;

    private NotificationStatus status;
    private int attempts;
    private String providerMessageId;
    private Instant sentAt;

    private Notification(UUID id, UUID userId, UUID videoId, String recipient, String subject,
                         String body, NotificationStatus status, int attempts,
                         String providerMessageId, Instant createdAt, Instant sentAt) {
        this.id = Objects.requireNonNull(id);
        this.userId = Objects.requireNonNull(userId);
        this.videoId = Objects.requireNonNull(videoId);
        this.recipient = Objects.requireNonNull(recipient);
        this.subject = Objects.requireNonNull(subject);
        this.body = Objects.requireNonNull(body);
        this.status = Objects.requireNonNull(status);
        this.attempts = attempts;
        this.providerMessageId = providerMessageId;
        this.createdAt = Objects.requireNonNull(createdAt);
        this.sentAt = sentAt;
    }

    public static Notification create(UUID userId, UUID videoId, String recipient,
                                      String subject, String body) {
        if (recipient == null || recipient.isBlank()) {
            throw new IllegalArgumentException("Destinatario obrigatorio");
        }
        return new Notification(UUID.randomUUID(), userId, videoId, recipient, subject, body,
                NotificationStatus.PENDING, 0, null, Instant.now(), null);
    }

    public static Notification rehydrate(UUID id, UUID userId, UUID videoId, String recipient,
                                         String subject, String body, NotificationStatus status,
                                         int attempts, String providerMessageId,
                                         Instant createdAt, Instant sentAt) {
        return new Notification(id, userId, videoId, recipient, subject, body, status, attempts,
                providerMessageId, createdAt, sentAt);
    }

    public void markSent(String providerMessageId) {
        exigirNaoEnviada();
        this.status = NotificationStatus.SENT;
        this.providerMessageId = providerMessageId;
        this.sentAt = Instant.now();
        this.attempts++;
    }

    public void markFailed() {
        exigirNaoEnviada();
        this.status = NotificationStatus.FAILED;
        this.attempts++;
    }

    public boolean isSent() {
        return status == NotificationStatus.SENT;
    }

    private void exigirNaoEnviada() {
        if (isSent()) {
            throw new IllegalStateException("Notificacao ja enviada: " + id);
        }
    }

    public UUID id() { return id; }
    public UUID userId() { return userId; }
    public UUID videoId() { return videoId; }
    public String channel() { return CHANNEL_EMAIL; }
    public String recipient() { return recipient; }
    public String subject() { return subject; }
    public String body() { return body; }
    public NotificationStatus status() { return status; }
    public int attempts() { return attempts; }
    public String providerMessageId() { return providerMessageId; }
    public Instant createdAt() { return createdAt; }
    public Instant sentAt() { return sentAt; }
}
```

`domain/FailureEmail.java`:
```java
package br.com.fiapx.notification.domain;

import br.com.fiapx.contracts.ErrorCode;

import java.util.UUID;

/** Texto do e-mail enviado quando o processamento de um vídeo falha (RF-05). */
public record FailureEmail(String subject, String body) {

    public static final String SUBJECT = "FIAP X: não conseguimos processar o seu vídeo";

    public static FailureEmail of(UUID videoId, ErrorCode errorCode, String technicalMessage) {
        ErrorCode codigo = errorCode == null ? ErrorCode.UNKNOWN : errorCode;
        String detalhe = technicalMessage == null || technicalMessage.isBlank()
                ? "sem detalhes" : technicalMessage;

        String body = """
                Olá,

                Não conseguimos processar o seu vídeo (id %s).

                Motivo: %s
                Detalhe técnico: %s - %s

                O vídeo aparece como FAILED na sua listagem. Você pode corrigir o arquivo e
                enviá-lo novamente.

                Equipe FIAP X
                """.formatted(videoId, motivo(codigo), codigo, detalhe);

        return new FailureEmail(SUBJECT, body);
    }

    static String motivo(ErrorCode codigo) {
        return switch (codigo) {
            case INVALID_FORMAT -> "o arquivo enviado não está em um formato de vídeo suportado.";
            case FFMPEG_FAILURE -> "o vídeo parece estar corrompido ou usa um codec não suportado.";
            case NO_FRAMES_EXTRACTED -> "não foi possível extrair nenhum quadro do vídeo.";
            case STORAGE_FAILURE -> "houve uma falha temporária no armazenamento; tente enviar novamente.";
            case TIMEOUT -> "o processamento excedeu o tempo limite; tente um vídeo menor.";
            case UNKNOWN -> "ocorreu um erro inesperado durante o processamento.";
        };
    }
}
```

`NotificationServiceApplication.java`:
```java
package br.com.fiapx.notification;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class NotificationServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(NotificationServiceApplication.class, args);
    }
}
```

- [ ] **Step 6: Rodar e confirmar que passam**

Run: `./mvnw test`
Expected: PASS — 6 testes de `NotificationTest` e 8 de `FailureEmailTest` (6 do parametrizado + 2).

- [ ] **Step 7: Commit**

```bash
git add -A
git update-index --chmod=+x mvnw
git commit -m "feat: dominio de notificacao de falha

Notification controla o ciclo PENDING -> SENT/FAILED e impede envio
duplicado. FailureEmail traduz cada ErrorCode num motivo legivel."
```

---

### Task 2: `notification-service` — persistência

**Files:**
- Create: `src/main/resources/db/migration/V1__create_notifications.sql`
- Create: `src/main/resources/application.yml`
- Create: `src/main/java/br/com/fiapx/notification/application/port/out/NotificationRepository.java`
- Create: `src/main/java/br/com/fiapx/notification/infrastructure/persistence/{NotificationEntity,SpringDataNotificationRepository,JpaNotificationRepository}.java`
- Test: `src/test/java/br/com/fiapx/notification/support/{PostgresTestContainer,LocalStackTestContainer}.java`
- Test: `src/test/java/br/com/fiapx/notification/infrastructure/persistence/JpaNotificationRepositoryIT.java`

**Interfaces:**
- Consumes: `Notification`, `NotificationStatus` (Task 1).
- Produces:
  - `NotificationRepository` (port): `void save(Notification notification)`, `Optional<Notification> findByVideoId(UUID videoId)`
  - `support.PostgresTestContainer` e `support.LocalStackTestContainer` (usados nas Tasks 4 e 5)

- [ ] **Step 1: Escrever a migration**

`src/main/resources/db/migration/V1__create_notifications.sql` (idêntico ao bloco `notification_db` de `sql/schema.sql`):
```sql
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
```

- [ ] **Step 2: Escrever o `application.yml`**

```yaml
server:
  port: 8084

spring:
  application:
    name: fiapx-notification-service
  datasource:
    url: ${DB_URL:jdbc:postgresql://localhost:5432/notification_db}
    username: ${DB_USER:fiapx}
    password: ${DB_PASSWORD:fiapx}
  jpa:
    hibernate:
      ddl-auto: validate
    open-in-view: false
  flyway:
    enabled: true
  mail:
    host: ${SMTP_HOST:localhost}
    port: ${SMTP_PORT:1025}

fiapx:
  sqs:
    notification-queue: ${SQS_NOTIFICATION_QUEUE:notification-queue}
  notification:
    # smtp (Mailpit no Compose) ou ses (AWS)
    provider: ${NOTIFICATION_PROVIDER:smtp}
    from: ${NOTIFICATION_FROM:nao-responda@fiapx.local}

spring.cloud.aws:
  region:
    static: ${AWS_REGION:us-east-1}
  endpoint: ${AWS_ENDPOINT:}
  credentials:
    # Vazio = cadeia padrão do SDK (IRSA no EKS). No Compose vêm do ambiente.
    access-key: ${AWS_ACCESS_KEY_ID:}
    secret-key: ${AWS_SECRET_ACCESS_KEY:}

management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  endpoint:
    health:
      probes:
        enabled: true
  health:
    # Na AWS o provedor é o SES e não há SMTP: o health de mail ficaria sempre DOWN.
    mail:
      enabled: false
```

- [ ] **Step 3: Escrever os containers de teste e o IT (falha)**

`src/test/java/br/com/fiapx/notification/support/PostgresTestContainer.java`:
```java
package br.com.fiapx.notification.support;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.testcontainers.containers.PostgreSQLContainer;

@TestConfiguration(proxyBeanMethods = false)
public class PostgresTestContainer {

    @Bean
    @ServiceConnection
    PostgreSQLContainer<?> postgres() {
        return new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("notification_db")
                .withUsername("fiapx")
                .withPassword("fiapx");
    }
}
```

`src/test/java/br/com/fiapx/notification/support/LocalStackTestContainer.java`:
```java
package br.com.fiapx.notification.support;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.testcontainers.containers.localstack.LocalStackContainer;
import org.testcontainers.utility.DockerImageName;

import static org.testcontainers.containers.localstack.LocalStackContainer.Service.SNS;
import static org.testcontainers.containers.localstack.LocalStackContainer.Service.SQS;

/**
 * Publica o endpoint do LocalStack como propriedades spring.cloud.aws.*, e não via
 * {@code @ServiceConnection}: o Boot não tem ConnectionDetails para o LocalStack.
 * Todo @SpringBootTest deste serviço importa esta classe: o @SqsListener (Task 5) sobe
 * com o contexto e, sem endpoint local, tentaria a AWS real.
 */
@TestConfiguration(proxyBeanMethods = false)
public class LocalStackTestContainer {

    @Bean
    LocalStackContainer localStack(DynamicPropertyRegistry registry) {
        LocalStackContainer container = new LocalStackContainer(DockerImageName.parse("localstack/localstack:3.8"))
                .withServices(SQS, SNS);
        registry.add("spring.cloud.aws.endpoint", () -> container.getEndpoint().toString());
        registry.add("spring.cloud.aws.region.static", container::getRegion);
        registry.add("spring.cloud.aws.credentials.access-key", container::getAccessKey);
        registry.add("spring.cloud.aws.credentials.secret-key", container::getSecretKey);
        return container;
    }
}
```

`src/test/java/br/com/fiapx/notification/infrastructure/persistence/JpaNotificationRepositoryIT.java`:
```java
package br.com.fiapx.notification.infrastructure.persistence;

import br.com.fiapx.notification.application.port.out.NotificationRepository;
import br.com.fiapx.notification.domain.Notification;
import br.com.fiapx.notification.domain.NotificationStatus;
import br.com.fiapx.notification.support.LocalStackTestContainer;
import br.com.fiapx.notification.support.PostgresTestContainer;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@Import({LocalStackTestContainer.class, PostgresTestContainer.class})
class JpaNotificationRepositoryIT {

    @Autowired
    NotificationRepository repository;

    private Notification nova(UUID videoId) {
        return Notification.create(UUID.randomUUID(), videoId, "aluno@fiap.com.br",
                "assunto", "corpo com acentuação");
    }

    @Test
    void salvaERecuperaPeloVideo() {
        UUID videoId = UUID.randomUUID();
        var notificacao = nova(videoId);

        repository.save(notificacao);

        var encontrada = repository.findByVideoId(videoId).orElseThrow();
        assertThat(encontrada.id()).isEqualTo(notificacao.id());
        assertThat(encontrada.status()).isEqualTo(NotificationStatus.PENDING);
        assertThat(encontrada.recipient()).isEqualTo("aluno@fiap.com.br");
        assertThat(encontrada.body()).isEqualTo("corpo com acentuação");
    }

    @Test
    void atualizaStatusEIdDoProvedor() {
        UUID videoId = UUID.randomUUID();
        var notificacao = nova(videoId);
        repository.save(notificacao);

        notificacao.markSent("msg-1");
        repository.save(notificacao);

        var encontrada = repository.findByVideoId(videoId).orElseThrow();
        assertThat(encontrada.status()).isEqualTo(NotificationStatus.SENT);
        assertThat(encontrada.providerMessageId()).isEqualTo("msg-1");
        assertThat(encontrada.attempts()).isEqualTo(1);
        assertThat(encontrada.sentAt()).isNotNull();
    }

    @Test
    void vazioParaVideoSemNotificacao() {
        assertThat(repository.findByVideoId(UUID.randomUUID())).isEmpty();
    }
}
```

- [ ] **Step 4: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*JpaNotificationRepositoryIT'`
Expected: FAIL na compilação — `NotificationRepository` não existe.

- [ ] **Step 5: Implementar o port e o adapter**

`application/port/out/NotificationRepository.java`:
```java
package br.com.fiapx.notification.application.port.out;

import br.com.fiapx.notification.domain.Notification;

import java.util.Optional;
import java.util.UUID;

public interface NotificationRepository {

    void save(Notification notification);

    /** A notificação mais recente do vídeo: um vídeo falha no máximo uma vez. */
    Optional<Notification> findByVideoId(UUID videoId);
}
```

`infrastructure/persistence/NotificationEntity.java`:
```java
package br.com.fiapx.notification.infrastructure.persistence;

import br.com.fiapx.notification.domain.Notification;
import br.com.fiapx.notification.domain.NotificationStatus;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "notifications")
class NotificationEntity {

    @Id
    private UUID id;

    @Column(name = "user_id", nullable = false)
    private UUID userId;

    @Column(name = "video_id", nullable = false)
    private UUID videoId;

    @Column(nullable = false, length = 20)
    private String channel;

    @Column(nullable = false)
    private String recipient;

    @Column(nullable = false)
    private String subject;

    @Column(nullable = false)
    private String body;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private NotificationStatus status;

    @Column(nullable = false)
    private int attempts;

    @Column(name = "provider_message_id")
    private String providerMessageId;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt;

    @Column(name = "sent_at")
    private Instant sentAt;

    protected NotificationEntity() {
    }

    static NotificationEntity from(Notification notification) {
        NotificationEntity e = new NotificationEntity();
        e.id = notification.id();
        e.userId = notification.userId();
        e.videoId = notification.videoId();
        e.channel = notification.channel();
        e.recipient = notification.recipient();
        e.subject = notification.subject();
        e.body = notification.body();
        e.status = notification.status();
        e.attempts = notification.attempts();
        e.providerMessageId = notification.providerMessageId();
        e.createdAt = notification.createdAt();
        e.sentAt = notification.sentAt();
        return e;
    }

    Notification toDomain() {
        return Notification.rehydrate(id, userId, videoId, recipient, subject, body, status,
                attempts, providerMessageId, createdAt, sentAt);
    }
}
```

`infrastructure/persistence/SpringDataNotificationRepository.java`:
```java
package br.com.fiapx.notification.infrastructure.persistence;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

interface SpringDataNotificationRepository extends JpaRepository<NotificationEntity, UUID> {

    Optional<NotificationEntity> findFirstByVideoIdOrderByCreatedAtDesc(UUID videoId);
}
```

`infrastructure/persistence/JpaNotificationRepository.java`:
```java
package br.com.fiapx.notification.infrastructure.persistence;

import br.com.fiapx.notification.application.port.out.NotificationRepository;
import br.com.fiapx.notification.domain.Notification;
import org.springframework.stereotype.Repository;

import java.util.Optional;
import java.util.UUID;

@Repository
class JpaNotificationRepository implements NotificationRepository {

    private final SpringDataNotificationRepository delegate;

    JpaNotificationRepository(SpringDataNotificationRepository delegate) {
        this.delegate = delegate;
    }

    @Override
    public void save(Notification notification) {
        delegate.save(NotificationEntity.from(notification));
    }

    @Override
    public Optional<Notification> findByVideoId(UUID videoId) {
        return delegate.findFirstByVideoIdOrderByCreatedAtDesc(videoId)
                .map(NotificationEntity::toDomain);
    }
}
```

- [ ] **Step 6: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*JpaNotificationRepositoryIT'`
Expected: PASS — Flyway aplica a `V1` e os 3 testes ficam verdes.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: persistencia das notificacoes com Flyway

Adapter JPA atras do port NotificationRepository. Os ITs ja sobem o
LocalStack porque o listener SQS da Task 5 inicia com o contexto."
```

---

### Task 3: `notification-service` — caso de uso de notificação de falha

**Files:**
- Create: `src/main/java/br/com/fiapx/notification/application/port/out/EmailSender.java`
- Create: `src/main/java/br/com/fiapx/notification/application/exception/EmailDeliveryException.java`
- Create: `src/main/java/br/com/fiapx/notification/application/usecase/NotifyVideoFailureUseCase.java`
- Test: `src/test/java/br/com/fiapx/notification/application/usecase/NotifyVideoFailureUseCaseTest.java`

**Interfaces:**
- Consumes: `Notification`, `FailureEmail` (Task 1); `NotificationRepository` (Task 2); `VideoFailedPayload`, `ErrorCode` (contracts).
- Produces:
  - `EmailSender` (port): `String send(String to, String subject, String body)` → id da mensagem no provedor; lança `EmailDeliveryException`
  - `EmailDeliveryException(String message, Throwable cause)` — `RuntimeException`
  - `NotifyVideoFailureUseCase.execute(VideoFailedPayload payload)` → `void`; relança `EmailDeliveryException` para o SQS reentregar

- [ ] **Step 1: Escrever o teste (falha)**

```java
package br.com.fiapx.notification.application.usecase;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.contracts.VideoFailedPayload;
import br.com.fiapx.notification.application.exception.EmailDeliveryException;
import br.com.fiapx.notification.application.port.out.EmailSender;
import br.com.fiapx.notification.application.port.out.NotificationRepository;
import br.com.fiapx.notification.domain.FailureEmail;
import br.com.fiapx.notification.domain.Notification;
import br.com.fiapx.notification.domain.NotificationStatus;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class NotifyVideoFailureUseCaseTest {

    private NotificationRepository repository;
    private EmailSender sender;
    private NotifyVideoFailureUseCase useCase;

    private final UUID videoId = UUID.randomUUID();
    private final UUID userId = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        repository = mock(NotificationRepository.class);
        sender = mock(EmailSender.class);
        useCase = new NotifyVideoFailureUseCase(repository, sender);
    }

    private VideoFailedPayload payload() {
        return new VideoFailedPayload(videoId, userId, "aluno@fiap.com.br",
                ErrorCode.FFMPEG_FAILURE, "ffmpeg retornou codigo 183", 1);
    }

    @Test
    void enviaOEmailEMarcaComoEnviada() {
        when(repository.findByVideoId(videoId)).thenReturn(Optional.empty());
        when(sender.send(anyString(), anyString(), anyString())).thenReturn("msg-1");

        useCase.execute(payload());

        verify(sender).send(eq("aluno@fiap.com.br"), eq(FailureEmail.SUBJECT),
                contains(videoId.toString()));
        ArgumentCaptor<Notification> salva = ArgumentCaptor.forClass(Notification.class);
        verify(repository).save(salva.capture());
        assertThat(salva.getValue().status()).isEqualTo(NotificationStatus.SENT);
        assertThat(salva.getValue().providerMessageId()).isEqualTo("msg-1");
        assertThat(salva.getValue().body()).contains("FFMPEG_FAILURE");
    }

    @Test
    void entregaDuplicadaDoEventoNaoReenviaOEmail() {
        var jaEnviada = Notification.create(userId, videoId, "aluno@fiap.com.br", "s", "b");
        jaEnviada.markSent("msg-1");
        when(repository.findByVideoId(videoId)).thenReturn(Optional.of(jaEnviada));

        useCase.execute(payload());

        verify(sender, never()).send(anyString(), anyString(), anyString());
        verify(repository, never()).save(any());
    }

    @Test
    void falhaDoProvedorMarcaFailedESobeAExcecao() {
        when(repository.findByVideoId(videoId)).thenReturn(Optional.empty());
        when(sender.send(anyString(), anyString(), anyString()))
                .thenThrow(new EmailDeliveryException("SES fora do ar", null));

        assertThatThrownBy(() -> useCase.execute(payload()))
                .isInstanceOf(EmailDeliveryException.class);

        ArgumentCaptor<Notification> salva = ArgumentCaptor.forClass(Notification.class);
        verify(repository).save(salva.capture());
        assertThat(salva.getValue().status()).isEqualTo(NotificationStatus.FAILED);
        assertThat(salva.getValue().attempts()).isEqualTo(1);
    }

    @Test
    void novaTentativaReaproveitaANotificacaoQueFalhou() {
        var falhou = Notification.create(userId, videoId, "aluno@fiap.com.br", "s", "b");
        falhou.markFailed();
        when(repository.findByVideoId(videoId)).thenReturn(Optional.of(falhou));
        when(sender.send(anyString(), anyString(), anyString())).thenReturn("msg-2");

        useCase.execute(payload());

        assertThat(falhou.isSent()).isTrue();
        assertThat(falhou.attempts()).isEqualTo(2);
        verify(repository).save(falhou);
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*NotifyVideoFailureUseCaseTest'`
Expected: FAIL na compilação — `NotifyVideoFailureUseCase`, `EmailSender` e `EmailDeliveryException` não existem.

- [ ] **Step 3: Implementar port, exceção e caso de uso**

`application/port/out/EmailSender.java`:
```java
package br.com.fiapx.notification.application.port.out;

public interface EmailSender {

    /**
     * @return identificador da mensagem no provedor (MessageId do SES ou Message-ID do SMTP)
     * @throws br.com.fiapx.notification.application.exception.EmailDeliveryException se o
     *         provedor recusar ou estiver indisponível
     */
    String send(String to, String subject, String body);
}
```

`application/exception/EmailDeliveryException.java`:
```java
package br.com.fiapx.notification.application.exception;

public class EmailDeliveryException extends RuntimeException {

    public EmailDeliveryException(String message, Throwable cause) {
        super(message, cause);
    }
}
```

`application/usecase/NotifyVideoFailureUseCase.java`:
```java
package br.com.fiapx.notification.application.usecase;

import br.com.fiapx.contracts.VideoFailedPayload;
import br.com.fiapx.notification.application.exception.EmailDeliveryException;
import br.com.fiapx.notification.application.port.out.EmailSender;
import br.com.fiapx.notification.application.port.out.NotificationRepository;
import br.com.fiapx.notification.domain.FailureEmail;
import br.com.fiapx.notification.domain.Notification;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

@Service
public class NotifyVideoFailureUseCase {

    private static final Logger log = LoggerFactory.getLogger(NotifyVideoFailureUseCase.class);

    private final NotificationRepository repository;
    private final EmailSender emailSender;

    public NotifyVideoFailureUseCase(NotificationRepository repository, EmailSender emailSender) {
        this.repository = repository;
        this.emailSender = emailSender;
    }

    /**
     * Idempotente por vídeo: o SQS entrega pelo menos uma vez, e o usuário não deve
     * receber o mesmo aviso duas vezes. Falha do provedor é gravada e relançada, para a
     * mensagem voltar à fila e ser tentada de novo (DLQ depois de 5 recebimentos).
     */
    public void execute(VideoFailedPayload payload) {
        var existente = repository.findByVideoId(payload.videoId());
        if (existente.isPresent() && existente.get().isSent()) {
            log.info("Falha do video {} ja notificada; evento duplicado ignorado", payload.videoId());
            return;
        }

        Notification notificacao = existente.orElseGet(() -> {
            FailureEmail email = FailureEmail.of(payload.videoId(), payload.errorCode(),
                    payload.errorMessage());
            return Notification.create(payload.userId(), payload.videoId(),
                    payload.userEmail(), email.subject(), email.body());
        });

        try {
            String providerMessageId = emailSender.send(notificacao.recipient(),
                    notificacao.subject(), notificacao.body());
            notificacao.markSent(providerMessageId);
            repository.save(notificacao);
            log.info("E-mail de falha enviado correlationId={} providerMessageId={}",
                    payload.videoId(), providerMessageId);
        } catch (EmailDeliveryException ex) {
            notificacao.markFailed();
            repository.save(notificacao);
            log.warn("Envio do e-mail de falha falhou correlationId={} tentativa={}",
                    payload.videoId(), notificacao.attempts(), ex);
            throw ex;
        }
    }
}
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*NotifyVideoFailureUseCaseTest'`
Expected: PASS — 4 testes verdes.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: caso de uso de notificacao de falha idempotente por video

Evento duplicado nao reenvia e-mail. Falha do provedor fica registrada
como FAILED e a excecao sobe para o SQS reentregar a mensagem."
```

---

### Task 4: `notification-service` — adapters de e-mail (SMTP e SES)

**Files:**
- Create: `src/main/java/br/com/fiapx/notification/infrastructure/email/{SmtpEmailSender,SesEmailSender}.java`
- Create: `src/main/java/br/com/fiapx/notification/infrastructure/config/SesConfig.java`
- Test: `src/test/java/br/com/fiapx/notification/support/Mailpit.java`
- Test: `src/test/java/br/com/fiapx/notification/infrastructure/email/{SmtpEmailSenderIT,SesEmailSenderIT}.java`

**Interfaces:**
- Consumes: `EmailSender`, `EmailDeliveryException` (Task 3).
- Produces:
  - `SmtpEmailSender(JavaMailSender mailSender, String from)` — ativo com `fiapx.notification.provider=smtp` (padrão)
  - `SesEmailSender(SesClient ses, String from)` — ativo com `fiapx.notification.provider=ses`
  - `support.Mailpit.container()` → `GenericContainer<?>` (portas 1025 e 8025); `support.Mailpit.mensagens(GenericContainer<?>)` → `JsonNode` da API `/api/v1/messages` (usado na Task 5)

- [ ] **Step 1: Escrever o helper do Mailpit e os testes (falham)**

`src/test/java/br/com/fiapx/notification/support/Mailpit.java`:
```java
package br.com.fiapx.notification.support;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.utility.DockerImageName;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

/** Servidor SMTP de teste com API HTTP para inspecionar as mensagens recebidas. */
public final class Mailpit {

    public static final int SMTP_PORT = 1025;
    public static final int API_PORT = 8025;

    private Mailpit() {
    }

    public static GenericContainer<?> container() {
        return new GenericContainer<>(DockerImageName.parse("axllent/mailpit:v1.31.1"))
                .withExposedPorts(SMTP_PORT, API_PORT)
                .waitingFor(Wait.forHttp("/api/v1/messages").forPort(API_PORT));
    }

    public static JsonNode mensagens(GenericContainer<?> mailpit) throws Exception {
        URI uri = URI.create("http://" + mailpit.getHost() + ":"
                + mailpit.getMappedPort(API_PORT) + "/api/v1/messages");
        HttpResponse<String> resposta = HttpClient.newHttpClient()
                .send(HttpRequest.newBuilder(uri).GET().build(), HttpResponse.BodyHandlers.ofString());
        return new ObjectMapper().readTree(resposta.body());
    }
}
```

`src/test/java/br/com/fiapx/notification/infrastructure/email/SmtpEmailSenderIT.java`:
```java
package br.com.fiapx.notification.infrastructure.email;

import br.com.fiapx.notification.application.exception.EmailDeliveryException;
import br.com.fiapx.notification.support.Mailpit;
import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.mail.javamail.JavaMailSenderImpl;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@Testcontainers
class SmtpEmailSenderIT {

    @Container
    static GenericContainer<?> mailpit = Mailpit.container();

    @Test
    void entregaOEmailNoServidorSmtp() throws Exception {
        JavaMailSenderImpl mail = new JavaMailSenderImpl();
        mail.setHost(mailpit.getHost());
        mail.setPort(mailpit.getMappedPort(Mailpit.SMTP_PORT));
        var sender = new SmtpEmailSender(mail, "nao-responda@fiapx.local");

        String id = sender.send("aluno@fiap.com.br", "Assunto de teste", "Corpo com acentuação");

        assertThat(id).isNotBlank();
        JsonNode resposta = Mailpit.mensagens(mailpit);
        assertThat(resposta.get("total").asInt()).isEqualTo(1);
        JsonNode mensagem = resposta.get("messages").get(0);
        assertThat(mensagem.get("Subject").asText()).isEqualTo("Assunto de teste");
        assertThat(mensagem.get("To").get(0).get("Address").asText()).isEqualTo("aluno@fiap.com.br");
    }

    @Test
    void servidorForaDoArViraEmailDeliveryException() {
        JavaMailSenderImpl mail = new JavaMailSenderImpl();
        mail.setHost("localhost");
        mail.setPort(1); // nada escuta na porta 1
        var sender = new SmtpEmailSender(mail, "nao-responda@fiapx.local");

        assertThatThrownBy(() -> sender.send("aluno@fiap.com.br", "s", "b"))
                .isInstanceOf(EmailDeliveryException.class);
    }
}
```

`src/test/java/br/com/fiapx/notification/infrastructure/email/SesEmailSenderIT.java`:
```java
package br.com.fiapx.notification.infrastructure.email;

import br.com.fiapx.notification.application.exception.EmailDeliveryException;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.localstack.LocalStackContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.ses.SesClient;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@Testcontainers
class SesEmailSenderIT {

    private static final String REMETENTE = "nao-responda@fiapx.local";

    @Container
    static LocalStackContainer localStack =
            new LocalStackContainer(DockerImageName.parse("localstack/localstack:3.8"))
                    .withServices(LocalStackContainer.Service.SES);

    private static SesClient ses(URI endpoint) {
        return SesClient.builder()
                .endpointOverride(endpoint)
                .region(Region.of(localStack.getRegion()))
                .credentialsProvider(StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(localStack.getAccessKey(), localStack.getSecretKey())))
                .build();
    }

    @Test
    void enviaPeloSesEDevolveOMessageId() throws Exception {
        SesClient ses = ses(localStack.getEndpoint());
        // Como no SES real, o remetente precisa ser uma identidade verificada.
        ses.verifyEmailIdentity(r -> r.emailAddress(REMETENTE));
        var sender = new SesEmailSender(ses, REMETENTE);

        String messageId = sender.send("aluno@fiap.com.br", "Assunto SES", "Corpo SES");

        assertThat(messageId).isNotBlank();
        // O LocalStack guarda os e-mails "enviados" e os expõe em /_aws/ses.
        URI enviados = URI.create(localStack.getEndpoint() + "/_aws/ses?email=" + REMETENTE);
        HttpResponse<String> resposta = HttpClient.newHttpClient()
                .send(HttpRequest.newBuilder(enviados).GET().build(), HttpResponse.BodyHandlers.ofString());
        assertThat(resposta.body()).contains("Assunto SES").contains("aluno@fiap.com.br");
    }

    @Test
    void sesIndisponivelViraEmailDeliveryException() {
        SesClient ses = ses(URI.create("http://localhost:1")); // nada escuta na porta 1
        var sender = new SesEmailSender(ses, REMETENTE);

        assertThatThrownBy(() -> sender.send("aluno@fiap.com.br", "s", "b"))
                .isInstanceOf(EmailDeliveryException.class);
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falham**

Run: `./mvnw test -Dtest='*EmailSenderIT'`
Expected: FAIL na compilação — `SmtpEmailSender` e `SesEmailSender` não existem.

- [ ] **Step 3: Implementar os adapters e a configuração do SES**

`infrastructure/email/SmtpEmailSender.java`:
```java
package br.com.fiapx.notification.infrastructure.email;

import br.com.fiapx.notification.application.exception.EmailDeliveryException;
import br.com.fiapx.notification.application.port.out.EmailSender;
import jakarta.mail.MessagingException;
import jakarta.mail.internet.MimeMessage;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.mail.MailException;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.mail.javamail.MimeMessageHelper;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.util.UUID;

/** Ambiente local: entrega no Mailpit, que mostra o e-mail em http://localhost:8025. */
@Component
@ConditionalOnProperty(name = "fiapx.notification.provider", havingValue = "smtp", matchIfMissing = true)
class SmtpEmailSender implements EmailSender {

    private final JavaMailSender mailSender;
    private final String from;

    SmtpEmailSender(JavaMailSender mailSender, @Value("${fiapx.notification.from}") String from) {
        this.mailSender = mailSender;
        this.from = from;
    }

    @Override
    public String send(String to, String subject, String body) {
        try {
            MimeMessage mensagem = mailSender.createMimeMessage();
            MimeMessageHelper helper = new MimeMessageHelper(mensagem, StandardCharsets.UTF_8.name());
            helper.setFrom(from);
            helper.setTo(to);
            helper.setSubject(subject);
            helper.setText(body, false);
            mailSender.send(mensagem);
            String messageId = mensagem.getMessageID();
            return messageId != null ? messageId : "smtp-" + UUID.randomUUID();
        } catch (MessagingException | MailException ex) {
            throw new EmailDeliveryException("Falha ao enviar e-mail via SMTP para " + to, ex);
        }
    }
}
```

`infrastructure/email/SesEmailSender.java`:
```java
package br.com.fiapx.notification.infrastructure.email;

import br.com.fiapx.notification.application.exception.EmailDeliveryException;
import br.com.fiapx.notification.application.port.out.EmailSender;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.core.exception.SdkException;
import software.amazon.awssdk.services.ses.SesClient;

/** AWS: envia pelo SES. No sandbox, remetente e destinatário precisam estar verificados. */
@Component
@ConditionalOnProperty(name = "fiapx.notification.provider", havingValue = "ses")
class SesEmailSender implements EmailSender {

    private final SesClient ses;
    private final String from;

    SesEmailSender(SesClient ses, @Value("${fiapx.notification.from}") String from) {
        this.ses = ses;
        this.from = from;
    }

    @Override
    public String send(String to, String subject, String body) {
        try {
            return ses.sendEmail(r -> r
                    .source(from)
                    .destination(d -> d.toAddresses(to))
                    .message(m -> m
                            .subject(c -> c.data(subject).charset("UTF-8"))
                            .body(b -> b.text(c -> c.data(body).charset("UTF-8")))))
                    .messageId();
        } catch (SdkException ex) {
            throw new EmailDeliveryException("Falha ao enviar e-mail via SES para " + to, ex);
        }
    }
}
```

`infrastructure/config/SesConfig.java`:
```java
package br.com.fiapx.notification.infrastructure.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.regions.providers.AwsRegionProvider;
import software.amazon.awssdk.services.ses.SesClient;
import software.amazon.awssdk.services.ses.SesClientBuilder;

import java.net.URI;

/**
 * Usa as mesmas credenciais e região do spring-cloud-aws: chaves estáticas quando
 * configuradas (LocalStack) e a cadeia padrão do SDK caso contrário (IRSA no EKS).
 */
@Configuration
@ConditionalOnProperty(name = "fiapx.notification.provider", havingValue = "ses")
class SesConfig {

    @Bean
    SesClient sesClient(AwsCredentialsProvider credentialsProvider, AwsRegionProvider regionProvider,
                        @Value("${spring.cloud.aws.endpoint:}") String endpoint) {
        SesClientBuilder builder = SesClient.builder()
                .credentialsProvider(credentialsProvider)
                .region(regionProvider.getRegion());
        if (!endpoint.isBlank()) {
            builder.endpointOverride(URI.create(endpoint));
        }
        return builder.build();
    }
}
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*EmailSenderIT'`
Expected: PASS — 4 testes verdes: e-mail no Mailpit, e-mail no SES do LocalStack e os dois casos de indisponibilidade virando `EmailDeliveryException`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: adapters de e-mail SMTP e SES selecionados por propriedade

fiapx.notification.provider=smtp entrega no Mailpit do ambiente local;
ses usa o SesClient com as credenciais do spring-cloud-aws (IRSA no EKS).
Qualquer falha do provedor vira EmailDeliveryException."
```

---

### Task 5: `notification-service` — listener da `notification-queue`

**Files:**
- Create: `src/main/java/br/com/fiapx/notification/infrastructure/messaging/NotificationListener.java`
- Test: `src/test/java/br/com/fiapx/notification/support/MailpitTestContainer.java`
- Test: `src/test/java/br/com/fiapx/notification/infrastructure/messaging/NotificationListenerIT.java`

**Interfaces:**
- Consumes: `NotifyVideoFailureUseCase` (Task 3); `SmtpEmailSender` (Task 4); `support.Mailpit`, `support.LocalStackTestContainer`, `support.PostgresTestContainer`; `EventEnvelope`, `EventType`, `VideoFailedPayload`, `VideoProcessedPayload`, `ContractsJson` (contracts).
- Produces: consumo de `${fiapx.sqs.notification-queue}`. Só `VideoFailed` gera notificação; os demais eventos do tópico são descartados.

- [ ] **Step 1: Escrever o container Spring do Mailpit e o IT (falha)**

`src/test/java/br/com/fiapx/notification/support/MailpitTestContainer.java`:
```java
package br.com.fiapx.notification.support;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.testcontainers.containers.GenericContainer;

@TestConfiguration(proxyBeanMethods = false)
public class MailpitTestContainer {

    @Bean
    GenericContainer<?> mailpit(DynamicPropertyRegistry registry) {
        GenericContainer<?> container = Mailpit.container();
        registry.add("spring.mail.host", container::getHost);
        registry.add("spring.mail.port", () -> container.getMappedPort(Mailpit.SMTP_PORT));
        return container;
    }
}
```

`src/test/java/br/com/fiapx/notification/infrastructure/messaging/NotificationListenerIT.java`:
```java
package br.com.fiapx.notification.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.EventType;
import br.com.fiapx.contracts.VideoFailedPayload;
import br.com.fiapx.contracts.VideoProcessedPayload;
import br.com.fiapx.notification.application.port.out.NotificationRepository;
import br.com.fiapx.notification.domain.FailureEmail;
import br.com.fiapx.notification.domain.NotificationStatus;
import br.com.fiapx.notification.support.LocalStackTestContainer;
import br.com.fiapx.notification.support.Mailpit;
import br.com.fiapx.notification.support.MailpitTestContainer;
import br.com.fiapx.notification.support.PostgresTestContainer;
import io.awspring.cloud.sqs.operations.SqsTemplate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.testcontainers.containers.GenericContainer;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;

import java.time.Duration;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

@SpringBootTest
@Import({LocalStackTestContainer.class, PostgresTestContainer.class, MailpitTestContainer.class})
class NotificationListenerIT {

    @Autowired SqsTemplate sqsTemplate;
    @Autowired SqsAsyncClient sqs; // o spring-cloud-aws só autoconfigura o cliente assíncrono
    @Autowired NotificationRepository repository;
    // Qualifier: LocalStack e Postgres também são GenericContainer.
    @Autowired @Qualifier("mailpit") GenericContainer<?> mailpit;

    @Value("${fiapx.sqs.notification-queue}")
    String fila;

    private String filaUrl;

    @BeforeEach
    void criarFila() {
        filaUrl = sqs.createQueue(b -> b.queueName(fila)).join().queueUrl();
    }

    private void publicar(EventEnvelope<?> envelope) throws Exception {
        // Serializa fora do lambda: a JsonProcessingException é checada.
        String json = ContractsJson.mapper().writeValueAsString(envelope);
        sqsTemplate.send(to -> to.queue(fila).payload(json));
    }

    @Test
    void videoFailedGeraEmailENotificacaoEnviada() throws Exception {
        UUID videoId = UUID.randomUUID();
        publicar(EventEnvelope.of(EventType.VIDEO_FAILED, videoId,
                new VideoFailedPayload(videoId, UUID.randomUUID(), "falha@fiap.com.br",
                        ErrorCode.FFMPEG_FAILURE, "ffmpeg retornou codigo 183", 1)));

        await().atMost(Duration.ofSeconds(30)).untilAsserted(() -> {
            var notificacao = repository.findByVideoId(videoId);
            assertThat(notificacao).isPresent();
            assertThat(notificacao.get().status()).isEqualTo(NotificationStatus.SENT);
        });

        String mensagens = Mailpit.mensagens(mailpit).toString();
        assertThat(mensagens).contains("falha@fiap.com.br").contains(FailureEmail.SUBJECT);
    }

    @Test
    void outrosEventosDoTopicoNaoGeramNotificacao() throws Exception {
        UUID videoId = UUID.randomUUID();
        publicar(EventEnvelope.of(EventType.VIDEO_PROCESSED, videoId,
                new VideoProcessedPayload(videoId, UUID.randomUUID(), "processed/u/v.zip", 2, 100L)));

        // Fila vazia (nem visível nem em processamento) = o evento já foi consumido.
        await().atMost(Duration.ofSeconds(30)).untilAsserted(() -> {
            var atributos = sqs.getQueueAttributes(b -> b.queueUrl(filaUrl)
                    .attributeNamesWithStrings("ApproximateNumberOfMessages",
                            "ApproximateNumberOfMessagesNotVisible"))
                    .join().attributesAsStrings();
            assertThat(atributos.get("ApproximateNumberOfMessages")).isEqualTo("0");
            assertThat(atributos.get("ApproximateNumberOfMessagesNotVisible")).isEqualTo("0");
        });

        assertThat(repository.findByVideoId(videoId)).isEmpty();
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*NotificationListenerIT'`
Expected: FAIL — sem listener, `videoFailedGeraEmailENotificacaoEnviada` estoura o `await` de 30 s (a notificação nunca aparece).

- [ ] **Step 3: Implementar o listener**

`infrastructure/messaging/NotificationListener.java`:
```java
package br.com.fiapx.notification.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.EventType;
import br.com.fiapx.contracts.VideoFailedPayload;
import br.com.fiapx.notification.application.usecase.NotifyVideoFailureUseCase;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.awspring.cloud.sqs.annotation.SqsListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

@Component
class NotificationListener {

    private static final Logger log = LoggerFactory.getLogger(NotificationListener.class);

    private final NotifyVideoFailureUseCase useCase;
    private final ObjectMapper mapper = ContractsJson.mapper();

    NotificationListener(NotifyVideoFailureUseCase useCase) {
        this.useCase = useCase;
    }

    /**
     * A notification-queue recebe todos os eventos do tópico video-events; só VideoFailed
     * interessa. Mensagem ilegível é descartada. EmailDeliveryException sobe de propósito:
     * a mensagem volta à fila e o envio é tentado de novo.
     */
    @SqsListener("${fiapx.sqs.notification-queue}")
    void onMessage(String body) {
        JsonNode raiz;
        try {
            raiz = mapper.readTree(body);
            // Assinatura SNS→SQS sem raw delivery embrulha o evento em "Message".
            if (raiz.has("Message") && raiz.has("TopicArn")) {
                raiz = mapper.readTree(raiz.get("Message").asText());
            }
        } catch (JsonProcessingException ex) {
            log.error("Mensagem descartada por JSON invalido: {}", body, ex);
            return;
        }

        String tipo = raiz.path("eventType").asText("");
        if (!EventType.VIDEO_FAILED.wireName().equals(tipo)) {
            log.debug("Evento {} ignorado: so VideoFailed gera notificacao", tipo);
            return;
        }

        EventEnvelope<VideoFailedPayload> envelope;
        try {
            envelope = mapper.convertValue(raiz, new TypeReference<>() {});
        } catch (IllegalArgumentException ex) {
            log.error("VideoFailed descartado por payload invalido: {}", body, ex);
            return;
        }

        useCase.execute(envelope.payload());
    }
}
```

- [ ] **Step 4: Rodar a suíte inteira**

Run: `./mvnw verify`
Expected: PASS — domínio, caso de uso, os quatro ITs e o gate do JaCoCo (`All coverage checks have been met`).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: listener da notification-queue envia e-mail em VideoFailed

Descarta os demais eventos do topico e mensagens ilegiveis; deixa a falha
do provedor subir para o SQS reentregar."
```

---

### Task 6: `notification-service` — imagem, Compose, E2E de e-mail e publicação

**Files:**
- Create: `services/fiapx-notification-service/{Dockerfile,.dockerignore,README.md}`
- Modify: `docker-compose.yml` (fiapx-infra) — serviços `mailpit` e `notification-service`
- Modify: `e2e/pom.xml` — propriedade `mailpit.url`
- Modify: `e2e/src/test/java/br/com/fiapx/e2e/VideoProcessingE2ETest.java` — teste do e-mail de falha

**Interfaces:**
- Consumes: o serviço completo (Tasks 1-5); a stack do Compose (Plano 1, Task 21).
- Produces: imagem `fiapx/notification-service:local`; Mailpit em `http://localhost:8025`; propriedade de sistema `mailpit.url` do E2E (vazia = teste de e-mail pulado, usado na AWS pela Task 15).

- [ ] **Step 1: Escrever `Dockerfile`, `.dockerignore` e `README.md`**

`Dockerfile`:
```dockerfile
# syntax=docker/dockerfile:1
# Contexto de build: services/ (o build instala o fiapx-contracts)
#   docker build -f fiapx-notification-service/Dockerfile -t fiapx/notification-service:local ..
FROM maven:3.9-eclipse-temurin-21-alpine AS build
WORKDIR /workspace

COPY fiapx-contracts/pom.xml /workspace/fiapx-contracts/pom.xml
COPY fiapx-contracts/src /workspace/fiapx-contracts/src
RUN mvn -B -q -f /workspace/fiapx-contracts/pom.xml install -DskipTests

COPY fiapx-notification-service/pom.xml /workspace/app/
WORKDIR /workspace/app
RUN mvn -B -q dependency:go-offline || true
COPY fiapx-notification-service/src /workspace/app/src
RUN mvn -B -q package -DskipTests

FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S fiapx && adduser -S fiapx -G fiapx
WORKDIR /app
COPY --from=build /workspace/app/target/*.jar app.jar
USER fiapx
EXPOSE 8084
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75"
HEALTHCHECK --interval=10s --timeout=3s --start-period=60s --retries=6 \
  CMD wget -qO- http://localhost:8084/actuator/health/readiness | grep -q UP || exit 1
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

`.dockerignore`:
```
.git
target
*.md
```

`README.md`:
```markdown
# fiapx-notification-service

Consome a `notification-queue` (assinada no tópico SNS `video-events`) e, quando o
evento é `VideoFailed`, envia um e-mail ao dono do vídeo com o motivo da falha (RF-05).
Cada envio fica registrado em `notification_db.notifications`; um evento duplicado não
gera um segundo e-mail.

| Provedor | Quando | Configuração |
|---|---|---|
| SMTP | Compose (Mailpit em http://localhost:8025) | `NOTIFICATION_PROVIDER=smtp`, `SMTP_HOST`, `SMTP_PORT` |
| SES | AWS | `NOTIFICATION_PROVIDER=ses`; credenciais via IRSA |

## Rodar os testes

    ./mvnw verify

Requer Docker: Testcontainers sobe PostgreSQL, LocalStack (SQS, SNS, SES) e Mailpit.

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `DB_URL` | `jdbc:postgresql://localhost:5432/notification_db` | JDBC |
| `DB_USER` / `DB_PASSWORD` | `fiapx` / `fiapx` | Credenciais do banco |
| `SQS_NOTIFICATION_QUEUE` | `notification-queue` | Fila de entrada |
| `NOTIFICATION_PROVIDER` | `smtp` | `smtp` ou `ses` |
| `NOTIFICATION_FROM` | `nao-responda@fiapx.local` | Remetente (no SES, identidade verificada) |
| `SMTP_HOST` / `SMTP_PORT` | `localhost` / `1025` | Servidor SMTP |
| `AWS_ENDPOINT` | vazio | LocalStack no ambiente local |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | vazio | Vazio = cadeia padrão do SDK (IRSA) |
```

- [ ] **Step 2: Construir a imagem**

```bash
cd services
docker build -f fiapx-notification-service/Dockerfile -t fiapx/notification-service:local .
```
Expected: build conclui; `docker images fiapx/notification-service:local` lista a imagem.

- [ ] **Step 3: Adicionar Mailpit e notification-service ao `docker-compose.yml`**

No `docker-compose.yml` da raiz, acrescente antes da chave `volumes:` do final:
```yaml
  mailpit:
    image: axllent/mailpit:v1.31.1
    # 8025 = caixa de entrada web e API; 1025 = SMTP
    ports: ["8025:8025", "1025:1025"]

  notification-service:
    build:
      context: ./services
      dockerfile: fiapx-notification-service/Dockerfile
    image: fiapx/notification-service:local
    depends_on:
      postgres: { condition: service_healthy }
      localstack: { condition: service_healthy }
      mailpit: { condition: service_started }
    environment:
      DB_URL: jdbc:postgresql://postgres:5432/notification_db
      DB_USER: fiapx
      DB_PASSWORD: fiapx
      AWS_ENDPOINT: http://localstack:4566
      AWS_REGION: us-east-1
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      SQS_NOTIFICATION_QUEUE: notification-queue
      NOTIFICATION_PROVIDER: smtp
      NOTIFICATION_FROM: nao-responda@fiapx.local
      SMTP_HOST: mailpit
      SMTP_PORT: "1025"
```

- [ ] **Step 4: Acrescentar o teste de e-mail ao E2E**

Em `e2e/pom.xml`, dentro de `<properties>`, logo abaixo de `<video.url>`:
```xml
        <!-- Vazio pula o teste de e-mail (na AWS o e-mail é conferido na caixa real) -->
        <mailpit.url>http://localhost:8025</mailpit.url>
```
e, em `<systemPropertyVariables>` do surefire, abaixo de `<video.url>`:
```xml
                        <mailpit.url>${mailpit.url}</mailpit.url>
```

Em `VideoProcessingE2ETest.java`:

1. Acrescente os imports:
```java
import org.junit.jupiter.api.Assumptions;
import static org.hamcrest.Matchers.greaterThanOrEqualTo;
```
2. Acrescente o campo, junto dos outros `static`:
```java
    private static String mailpitUrl;
```
3. No `setUp()`, logo abaixo de `videoUrl = ...`:
```java
        mailpitUrl = System.getProperty("mailpit.url", "http://localhost:8025");
```
4. Acrescente o teste ao final da classe:
```java
    @Test
    void falhaNoProcessamentoEnviaEmailAoUsuario() throws Exception {
        Assumptions.assumeFalse(mailpitUrl.isBlank(),
                "Sem Mailpit (ambiente AWS): o e-mail é conferido na caixa de entrada real");
        String email = "e2e-falha-" + UUID.randomUUID() + "@fiap.com.br";
        String token = registrarELogar(email);
        File quebrado = Files.writeString(Files.createTempFile("quebrado", ".mp4"),
                "isto nao e um video").toFile();

        String videoId = given().baseUri(videoUrl).header("Authorization", "Bearer " + token)
                .multiPart("video", quebrado)
                .post("/api/v1/videos")
                .then().statusCode(202)
                .extract().path("id");

        await().atMost(Duration.ofMinutes(1)).pollInterval(Duration.ofSeconds(2))
                .untilAsserted(() ->
                        given().baseUri(videoUrl).header("Authorization", "Bearer " + token)
                                .get("/api/v1/videos/" + videoId)
                                .then().statusCode(200)
                                .body("status", org.hamcrest.Matchers.equalTo("FAILED")));

        await().atMost(Duration.ofMinutes(1)).pollInterval(Duration.ofSeconds(2))
                .untilAsserted(() ->
                        given().baseUri(mailpitUrl).queryParam("query", "to:" + email)
                                .get("/api/v1/search")
                                .then().statusCode(200)
                                .body("messages.size()", greaterThanOrEqualTo(1)));
    }
```

- [ ] **Step 5: Subir o ambiente e rodar o E2E**

```bash
docker compose up --build -d --wait --wait-timeout 420
docker compose ps --format '{{.Service}}  {{.Status}}'
cd e2e && ./mvnw -B test
```
Expected: todos os serviços `healthy` (o Mailpit `running`, sem healthcheck) e **6** testes verdes. Em http://localhost:8025 aparece o e-mail "FIAP X: não conseguimos processar o seu vídeo".

- [ ] **Step 6: Commit no `fiapx-notification-service` e publicação**

```bash
cd services/fiapx-notification-service
git add -A
git commit -m "build: imagem do notification-service e README"
gh repo create celiovetrano/fiapx-notification-service --public --source . \
  --remote origin --push --description "FIAP X - Hackathon POSTECH SOAT Fase 5"
git log --format='%ae' | sort -u
```
Expected: push aceito; o único e-mail nos commits é o noreply.

- [ ] **Step 7: Commit no `fiapx-infra`**

```bash
git add docker-compose.yml e2e
git commit -m "feat: notification-service e Mailpit no ambiente local

O E2E envia um arquivo corrompido e confere o e-mail de falha no Mailpit
(RF-05). Com -Dmailpit.url= vazio o teste e pulado, para rodar na AWS."
git push
```

---

## Parte B — gateway e UI (D4, tarde)

> Lista de corte (spec §19): se o D4 atrasar meio dia, a Task 9 (UI) cai para Swagger UI;
> se atrasar mais, o gateway inteiro cai para um Ingress roteando direto aos serviços.

### Task 7: `gateway` — repositório, pom e limitador de tentativas

**Files:**
- Create: `services/fiapx-gateway/pom.xml`
- Create: `src/main/java/br/com/fiapx/gateway/GatewayApplication.java`
- Create: `src/main/java/br/com/fiapx/gateway/ratelimit/FixedWindowRateLimiter.java`
- Test: `src/test/java/br/com/fiapx/gateway/ratelimit/FixedWindowRateLimiterTest.java`

**Interfaces:**
- Consumes: nada.
- Produces: `FixedWindowRateLimiter(int maxRequests, Duration window, Clock clock)` com `boolean tryAcquire(String key)` — `true` enquanto a chave não passou do limite na janela corrente.

- [ ] **Step 1: Criar o repositório**

```bash
cd services && mkdir -p fiapx-gateway && cd fiapx-gateway
git init -b main
git config user.email "149624872+celiovetrano@users.noreply.github.com"
cp -r ../fiapx-contracts/mvnw ../fiapx-contracts/mvnw.cmd ../fiapx-contracts/.mvn \
      ../fiapx-contracts/.gitattributes ../fiapx-contracts/.gitignore .
```

- [ ] **Step 2: Escrever o `pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>3.3.5</version>
        <relativePath/>
    </parent>

    <groupId>br.com.fiapx</groupId>
    <artifactId>fiapx-gateway</artifactId>
    <version>1.0.0</version>

    <properties>
        <java.version>21</java.version>
        <!-- 2023.0.x é a linha compatível com o Boot 3.3; a 2024.0 exige Boot 3.4. -->
        <spring-cloud.version>2023.0.6</spring-cloud.version>
    </properties>

    <dependencyManagement>
        <dependencies>
            <dependency>
                <groupId>org.springframework.cloud</groupId>
                <artifactId>spring-cloud-dependencies</artifactId>
                <version>${spring-cloud.version}</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
        </dependencies>
    </dependencyManagement>

    <dependencies>
        <!-- Gateway é WebFlux: não inclua spring-boot-starter-web. -->
        <dependency>
            <groupId>org.springframework.cloud</groupId>
            <artifactId>spring-cloud-starter-gateway</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-actuator</artifactId>
        </dependency>
        <dependency>
            <groupId>io.micrometer</groupId>
            <artifactId>micrometer-registry-prometheus</artifactId>
            <scope>runtime</scope>
        </dependency>

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.projectreactor</groupId>
            <artifactId>reactor-test</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.springframework.security</groupId>
            <artifactId>spring-security-test</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>com.squareup.okhttp3</groupId>
            <artifactId>mockwebserver</artifactId>
            <version>${okhttp.version}</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-surefire-plugin</artifactId>
                <configuration>
                    <includes>
                        <include>**/*Test.java</include>
                        <include>**/*IT.java</include>
                    </includes>
                </configuration>
            </plugin>
            <plugin>
                <groupId>org.jacoco</groupId>
                <artifactId>jacoco-maven-plugin</artifactId>
                <version>0.8.12</version>
                <executions>
                    <execution>
                        <id>prepare-agent</id>
                        <goals><goal>prepare-agent</goal></goals>
                    </execution>
                    <execution>
                        <id>report</id>
                        <phase>test</phase>
                        <goals><goal>report</goal></goals>
                    </execution>
                    <execution>
                        <id>check</id>
                        <goals><goal>check</goal></goals>
                        <configuration>
                            <rules>
                                <!-- O gateway não tem domínio: a regra de negócio é o limitador. -->
                                <rule>
                                    <element>PACKAGE</element>
                                    <includes>
                                        <include>br.com.fiapx.gateway.ratelimit*</include>
                                    </includes>
                                    <limits>
                                        <limit>
                                            <counter>LINE</counter>
                                            <value>COVEREDRATIO</value>
                                            <minimum>0.80</minimum>
                                        </limit>
                                    </limits>
                                </rule>
                            </rules>
                        </configuration>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 3: Escrever o teste do limitador (falha)**

```java
package br.com.fiapx.gateway.ratelimit;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;

class FixedWindowRateLimiterTest {

    private final RelogioAjustavel relogio = new RelogioAjustavel(Instant.parse("2026-09-15T10:00:00Z"));
    private final FixedWindowRateLimiter limiter =
            new FixedWindowRateLimiter(3, Duration.ofMinutes(1), relogio);

    @Test
    void permiteAteOLimiteDentroDaJanela() {
        assertThat(limiter.tryAcquire("10.0.0.1")).isTrue();
        assertThat(limiter.tryAcquire("10.0.0.1")).isTrue();
        assertThat(limiter.tryAcquire("10.0.0.1")).isTrue();
        assertThat(limiter.tryAcquire("10.0.0.1")).isFalse();
    }

    @Test
    void chavesDiferentesTemContagensIndependentes() {
        for (int i = 0; i < 3; i++) {
            limiter.tryAcquire("10.0.0.1");
        }

        assertThat(limiter.tryAcquire("10.0.0.1")).isFalse();
        assertThat(limiter.tryAcquire("10.0.0.2")).isTrue();
    }

    @Test
    void novaJanelaZeraAContagem() {
        for (int i = 0; i < 4; i++) {
            limiter.tryAcquire("10.0.0.1");
        }

        relogio.avancar(Duration.ofMinutes(1));

        assertThat(limiter.tryAcquire("10.0.0.1")).isTrue();
    }

    static final class RelogioAjustavel extends Clock {

        private Instant agora;

        RelogioAjustavel(Instant inicio) {
            this.agora = inicio;
        }

        void avancar(Duration duracao) {
            agora = agora.plus(duracao);
        }

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return agora;
        }
    }
}
```

- [ ] **Step 4: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*FixedWindowRateLimiterTest'`
Expected: FAIL na compilação — `FixedWindowRateLimiter` não existe.

- [ ] **Step 5: Implementar o limitador e a aplicação**

`ratelimit/FixedWindowRateLimiter.java`:
```java
package br.com.fiapx.gateway.ratelimit;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Janela fixa em memória, por chave (IP do cliente). Cada réplica do gateway conta as
 * suas próprias tentativas: com 2 réplicas o limite efetivo dobra, o que é aceitável
 * para conter força bruta. Um limite global exigiria Redis (corte 1 da spec §19).
 */
public class FixedWindowRateLimiter {

    private record Janela(Instant inicio, int contagem) {
    }

    private final int maxRequests;
    private final Duration window;
    private final Clock clock;
    private final ConcurrentHashMap<String, Janela> janelas = new ConcurrentHashMap<>();

    public FixedWindowRateLimiter(int maxRequests, Duration window, Clock clock) {
        this.maxRequests = maxRequests;
        this.window = window;
        this.clock = clock;
    }

    public boolean tryAcquire(String key) {
        Instant agora = clock.instant();
        Janela janela = janelas.compute(key, (chave, atual) ->
                atual == null || !agora.isBefore(atual.inicio().plus(window))
                        ? new Janela(agora, 1)
                        : new Janela(atual.inicio(), atual.contagem() + 1));
        return janela.contagem() <= maxRequests;
    }
}
```

`GatewayApplication.java`:
```java
package br.com.fiapx.gateway;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class GatewayApplication {
    public static void main(String[] args) {
        SpringApplication.run(GatewayApplication.class, args);
    }
}
```

- [ ] **Step 6: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*FixedWindowRateLimiterTest'`
Expected: PASS — 3 testes verdes.

- [ ] **Step 7: Commit**

```bash
git add -A
git update-index --chmod=+x mvnw
git commit -m "feat: limitador de tentativas por janela fixa

Base do rate limit de login do gateway, em memoria e por IP."
```

---

### Task 8: `gateway` — rotas, validação do JWT e rate limit de login

**Files:**
- Create: `src/main/resources/application.yml`
- Create: `src/main/java/br/com/fiapx/gateway/config/SecurityConfig.java`
- Create: `src/main/java/br/com/fiapx/gateway/ratelimit/LoginRateLimitFilter.java`
- Test: `src/test/java/br/com/fiapx/gateway/GatewayRoutingTest.java`
- Test: `src/test/java/br/com/fiapx/gateway/ratelimit/LoginRateLimitFilterTest.java`

**Interfaces:**
- Consumes: `FixedWindowRateLimiter` (Task 7).
- Produces:
  - Rotas: `/api/v1/auth/**` e `/.well-known/**` → `${AUTH_SERVICE_URL}`; `/api/v1/videos/**` → `${VIDEO_API_URL}`
  - Públicos sem token: `/`, `/index.html`, `/app.js`, `/styles.css`, `/favicon.ico`, `/actuator/**`, `/.well-known/**`, `POST /api/v1/auth/register`, `POST /api/v1/auth/login`
  - `POST /api/v1/auth/login` acima de `fiapx.gateway.login-rate-limit.max-attempts` (padrão 10) por minuto e por IP → `429` em `application/problem+json`

- [ ] **Step 1: Escrever o `application.yml`**

```yaml
server:
  port: 8080

spring:
  application:
    name: fiapx-gateway
  security:
    oauth2:
      resourceserver:
        jwt:
          jwk-set-uri: ${JWKS_URI:http://localhost:8081/.well-known/jwks.json}
  cloud:
    gateway:
      routes:
        - id: auth-service
          uri: ${AUTH_SERVICE_URL:http://localhost:8081}
          predicates:
            - Path=/api/v1/auth/**,/.well-known/**
        - id: video-api
          uri: ${VIDEO_API_URL:http://localhost:8082}
          predicates:
            # "/**" também casa com /api/v1/videos (zero segmentos)
            - Path=/api/v1/videos/**

fiapx:
  gateway:
    login-rate-limit:
      max-attempts: 10
      window: 1m

management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  endpoint:
    health:
      probes:
        enabled: true
```

- [ ] **Step 2: Escrever os testes (falham)**

`src/test/java/br/com/fiapx/gateway/GatewayRoutingTest.java`:
```java
package br.com.fiapx.gateway;

import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.RecordedRequest;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.ReactiveJwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.reactive.server.WebTestClient;
import reactor.core.publisher.Mono;

import java.io.IOException;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class GatewayRoutingTest {

    static final MockWebServer auth = new MockWebServer();
    static final MockWebServer videos = new MockWebServer();

    @DynamicPropertySource
    static void rotas(DynamicPropertyRegistry registry) throws IOException {
        auth.start();
        videos.start();
        registry.add("AUTH_SERVICE_URL", () -> "http://" + auth.getHostName() + ":" + auth.getPort());
        registry.add("VIDEO_API_URL", () -> "http://" + videos.getHostName() + ":" + videos.getPort());
    }

    @AfterAll
    static void parar() throws IOException {
        auth.shutdown();
        videos.shutdown();
    }

    @MockBean
    ReactiveJwtDecoder jwtDecoder;

    @Autowired
    WebTestClient client;

    @Test
    void loginERoteadoParaOAuthServiceSemToken() throws Exception {
        auth.enqueue(new MockResponse().setResponseCode(200)
                .setHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                .setBody("{\"accessToken\":\"abc\"}"));

        client.post().uri("/api/v1/auth/login")
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"a@b.com\",\"password\":\"fiapx2026\"}")
                .exchange()
                .expectStatus().isOk()
                .expectBody().jsonPath("$.accessToken").isEqualTo("abc");

        RecordedRequest recebida = auth.takeRequest(5, TimeUnit.SECONDS);
        assertThat(recebida).isNotNull();
        assertThat(recebida.getPath()).isEqualTo("/api/v1/auth/login");
    }

    @Test
    void videosSemTokenRecebem401NoGateway() {
        client.get().uri("/api/v1/videos")
                .exchange()
                .expectStatus().isUnauthorized();
    }

    @Test
    void tokenInvalidoRecebe401() {
        when(jwtDecoder.decode("token-invalido")).thenReturn(Mono.error(new BadJwtException("assinatura")));

        client.get().uri("/api/v1/videos")
                .header(HttpHeaders.AUTHORIZATION, "Bearer token-invalido")
                .exchange()
                .expectStatus().isUnauthorized();
    }

    @Test
    void videosComTokenValidoSaoRoteadosComOAuthorization() throws Exception {
        Jwt jwt = Jwt.withTokenValue("token-valido")
                .header("alg", "RS256")
                .subject(UUID.randomUUID().toString())
                .claim("email", "aluno@fiap.com.br")
                .build();
        when(jwtDecoder.decode("token-valido")).thenReturn(Mono.just(jwt));
        videos.enqueue(new MockResponse().setResponseCode(200)
                .setHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                .setBody("{\"items\":[],\"total\":0}"));

        client.get().uri("/api/v1/videos")
                .header(HttpHeaders.AUTHORIZATION, "Bearer token-valido")
                .exchange()
                .expectStatus().isOk()
                .expectBody().jsonPath("$.total").isEqualTo(0);

        // Defesa em profundidade (spec §9): o video-api revalida o mesmo token.
        RecordedRequest recebida = videos.takeRequest(5, TimeUnit.SECONDS);
        assertThat(recebida).isNotNull();
        assertThat(recebida.getHeader(HttpHeaders.AUTHORIZATION)).isEqualTo("Bearer token-valido");
    }
}
```

`src/test/java/br/com/fiapx/gateway/ratelimit/LoginRateLimitFilterTest.java`:
```java
package br.com.fiapx.gateway.ratelimit;

import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.jwt.ReactiveJwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.reactive.server.WebTestClient;

import java.io.IOException;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = "fiapx.gateway.login-rate-limit.max-attempts=3")
class LoginRateLimitFilterTest {

    static final MockWebServer auth = new MockWebServer();

    @DynamicPropertySource
    static void rotas(DynamicPropertyRegistry registry) throws IOException {
        auth.start();
        String url = "http://" + auth.getHostName() + ":" + auth.getPort();
        registry.add("AUTH_SERVICE_URL", () -> url);
        registry.add("VIDEO_API_URL", () -> url);
    }

    @AfterAll
    static void parar() throws IOException {
        auth.shutdown();
    }

    @MockBean
    ReactiveJwtDecoder jwtDecoder;

    @Autowired
    WebTestClient client;

    private WebTestClient.ResponseSpec post(String caminho) {
        return client.post().uri(caminho)
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue("{\"email\":\"a@b.com\",\"password\":\"errada123\",\"fullName\":\"A\"}")
                .exchange();
    }

    @Test
    void quartaTentativaDeLoginNoMesmoMinutoRecebe429() {
        int antes = auth.getRequestCount();
        for (int i = 0; i < 3; i++) {
            auth.enqueue(new MockResponse().setResponseCode(401)
                    .setHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_PROBLEM_JSON_VALUE)
                    .setBody("{\"title\":\"Credenciais invalidas\"}"));
            post("/api/v1/auth/login").expectStatus().isUnauthorized();
        }

        post("/api/v1/auth/login")
                .expectStatus().isEqualTo(429)
                .expectHeader().contentTypeCompatibleWith(MediaType.APPLICATION_PROBLEM_JSON)
                .expectBody().jsonPath("$.title").isEqualTo("Muitas tentativas de login");

        // A quarta tentativa nem chega ao auth-service.
        assertThat(auth.getRequestCount() - antes).isEqualTo(3);
    }

    @Test
    void cadastroNaoEntraNoLimiteDoLogin() {
        for (int i = 0; i < 4; i++) {
            auth.enqueue(new MockResponse().setResponseCode(201)
                    .setHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                    .setBody("{}"));
            post("/api/v1/auth/register").expectStatus().isCreated();
        }
    }
}
```

- [ ] **Step 3: Rodar e confirmar que falham**

Run: `./mvnw test`
Expected: FAIL — sem o `SecurityConfig`, a segurança padrão do Spring exige login em `/api/v1/auth/login` (401/redirect) e o `429` nunca aparece.

- [ ] **Step 4: Implementar segurança e filtro**

`config/SecurityConfig.java`:
```java
package br.com.fiapx.gateway.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.reactive.EnableWebFluxSecurity;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.web.server.SecurityWebFilterChain;

/**
 * O gateway valida o JWT antes de rotear; cada serviço revalida o mesmo token
 * (defesa em profundidade, spec §9). Nenhum header é injetado para os serviços.
 */
@Configuration
@EnableWebFluxSecurity
public class SecurityConfig {

    @Bean
    SecurityWebFilterChain securityWebFilterChain(ServerHttpSecurity http) {
        return http
                .csrf(ServerHttpSecurity.CsrfSpec::disable)
                .authorizeExchange(exchange -> exchange
                        .pathMatchers("/", "/index.html", "/app.js", "/styles.css", "/favicon.ico").permitAll()
                        .pathMatchers("/actuator/**", "/.well-known/**").permitAll()
                        .pathMatchers(HttpMethod.POST, "/api/v1/auth/register", "/api/v1/auth/login").permitAll()
                        .anyExchange().authenticated())
                .oauth2ResourceServer(oauth -> oauth.jwt(Customizer.withDefaults()))
                .build();
    }
}
```

`ratelimit/LoginRateLimitFilter.java`:
```java
package br.com.fiapx.gateway.ratelimit;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;

/** Contém força bruta no login (spec §9): N tentativas por minuto e por IP. */
@Component
public class LoginRateLimitFilter implements GlobalFilter, Ordered {

    private static final String LOGIN = "/api/v1/auth/login";
    private static final byte[] PROBLEMA = """
            {"type":"about:blank","title":"Muitas tentativas de login","status":429,\
            "detail":"Aguarde um minuto antes de tentar novamente."}"""
            .getBytes(StandardCharsets.UTF_8);

    private final FixedWindowRateLimiter limiter;

    public LoginRateLimitFilter(
            @Value("${fiapx.gateway.login-rate-limit.max-attempts}") int maxAttempts,
            @Value("${fiapx.gateway.login-rate-limit.window}") Duration window) {
        this.limiter = new FixedWindowRateLimiter(maxAttempts, window, Clock.systemUTC());
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();
        boolean login = HttpMethod.POST.equals(request.getMethod())
                && LOGIN.equals(request.getPath().value());
        if (!login || limiter.tryAcquire(cliente(request))) {
            return chain.filter(exchange);
        }
        ServerHttpResponse response = exchange.getResponse();
        response.setStatusCode(HttpStatus.TOO_MANY_REQUESTS);
        response.getHeaders().setContentType(MediaType.APPLICATION_PROBLEM_JSON);
        DataBuffer corpo = response.bufferFactory().wrap(PROBLEMA);
        return response.writeWith(Mono.just(corpo));
    }

    /** Atrás do load balancer da AWS o IP real vem no X-Forwarded-For. */
    private static String cliente(ServerHttpRequest request) {
        String encaminhado = request.getHeaders().getFirst("X-Forwarded-For");
        if (encaminhado != null && !encaminhado.isBlank()) {
            return encaminhado.split(",")[0].trim();
        }
        InetSocketAddress remoto = request.getRemoteAddress();
        return remoto != null ? remoto.getAddress().getHostAddress() : "desconhecido";
    }

    @Override
    public int getOrder() {
        return Ordered.HIGHEST_PRECEDENCE;
    }
}
```

- [ ] **Step 5: Rodar a suíte**

Run: `./mvnw verify`
Expected: PASS — 3 testes do limitador, 4 de roteamento, 2 do filtro e o gate do JaCoCo.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: rotas do gateway, validacao de JWT e rate limit de login

Auth e .well-known roteiam para o auth-service, /api/v1/videos para o
video-api. O gateway rejeita token ausente ou invalido com 401 e repassa o
Authorization para o servico revalidar. Login acima do limite recebe 429."
```

---

### Task 9: `gateway` — UI estática, imagem, Compose e publicação

**Files:**
- Create: `src/main/resources/static/{index.html,app.js,styles.css}`
- Test: `src/test/java/br/com/fiapx/gateway/UiTest.java`
- Create: `services/fiapx-gateway/{Dockerfile,.dockerignore,README.md}`
- Modify: `docker-compose.yml` (fiapx-infra) — serviço `gateway`

**Interfaces:**
- Consumes: rotas e segurança (Task 8); API do auth-service e do video-api (Plano 1).
- Produces: UI em `http://localhost:8080/`; imagem `fiapx/gateway:local`; o E2E roda através do gateway com `-Dauth.url=http://localhost:8080 -Dvideo.url=http://localhost:8080`.

- [ ] **Step 1: Escrever o teste da UI (falha)**

`src/test/java/br/com/fiapx/gateway/UiTest.java`:
```java
package br.com.fiapx.gateway;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.jwt.ReactiveJwtDecoder;
import org.springframework.test.web.reactive.server.WebTestClient;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class UiTest {

    @MockBean
    ReactiveJwtDecoder jwtDecoder;

    @Autowired
    WebTestClient client;

    @Test
    void paginaInicialServeAUiSemToken() {
        client.get().uri("/")
                .exchange()
                .expectStatus().isOk()
                .expectHeader().contentTypeCompatibleWith(MediaType.TEXT_HTML)
                .expectBody(String.class)
                .value(html -> assertThat(html).contains("FIAP X").contains("/app.js"));
    }

    @Test
    void scriptDaUiEPublico() {
        client.get().uri("/app.js")
                .exchange()
                .expectStatus().isOk()
                .expectBody(String.class)
                .value(js -> assertThat(js).contains("/api/v1/videos"));
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*UiTest'`
Expected: FAIL — `GET /` responde 404, porque ainda não há `static/index.html`.

- [ ] **Step 3: Escrever a UI**

`src/main/resources/static/index.html`:
```html
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>FIAP X — Processador de Vídeos</title>
  <link rel="stylesheet" href="/styles.css">
</head>
<body>
  <header class="topo">
    <div>
      <h1>FIAP X</h1>
      <p>Envie um vídeo e baixe os quadros em um arquivo ZIP.</p>
    </div>
    <button id="sair" class="secundario" hidden>Sair</button>
  </header>

  <main>
    <section id="acesso" class="cartao">
      <h2>Entrar</h2>
      <form id="form-login">
        <label>E-mail <input name="email" type="email" required autocomplete="username"></label>
        <label>Senha <input name="password" type="password" required minlength="8" autocomplete="current-password"></label>
        <button type="submit">Entrar</button>
      </form>
      <details>
        <summary>Não tem conta? Cadastre-se</summary>
        <form id="form-cadastro">
          <label>Nome <input name="fullName" required maxlength="120"></label>
          <label>E-mail <input name="email" type="email" required autocomplete="username"></label>
          <label>Senha <input name="password" type="password" required minlength="8"
                             placeholder="8+ caracteres, com letras e números" autocomplete="new-password"></label>
          <button type="submit">Cadastrar</button>
        </form>
      </details>
    </section>

    <section id="painel" hidden>
      <div class="cartao">
        <h2>Novo vídeo</h2>
        <form id="form-upload">
          <input name="video" type="file" accept=".mp4,.avi,.mov,.mkv,.wmv,.flv,.webm" required>
          <button type="submit">Enviar</button>
        </form>
        <p class="dica">mp4, avi, mov, mkv, wmv, flv ou webm, até 200 MB. O processamento é assíncrono:
          a lista abaixo se atualiza sozinha.</p>
      </div>
      <div class="cartao">
        <h2>Meus vídeos</h2>
        <div class="tabela">
          <table>
            <thead><tr><th>Arquivo</th><th>Status</th><th>Quadros</th><th>Enviado em</th><th></th></tr></thead>
            <tbody id="lista"></tbody>
          </table>
        </div>
      </div>
    </section>

    <p id="mensagem" role="status" aria-live="polite"></p>
  </main>

  <script src="/app.js"></script>
</body>
</html>
```

`src/main/resources/static/app.js`:
```javascript
'use strict';

const CHAVE_TOKEN = 'fiapx.token';
let token = sessionStorage.getItem(CHAVE_TOKEN);
let atualizacao = null;

const el = (id) => document.getElementById(id);

function mostrarMensagem(texto, erro = false) {
  const mensagem = el('mensagem');
  mensagem.textContent = texto;
  mensagem.className = erro ? 'erro' : 'ok';
}

async function api(caminho, opcoes = {}) {
  const headers = { ...(opcoes.headers || {}) };
  if (token) headers.Authorization = `Bearer ${token}`;
  const resposta = await fetch(caminho, { ...opcoes, headers });
  if (resposta.status === 401 && token) {
    sair();
    throw new Error('Sessão expirada. Entre novamente.');
  }
  const corpo = await resposta.json().catch(() => null);
  if (!resposta.ok) {
    throw new Error((corpo && (corpo.detail || corpo.title)) || `Erro ${resposta.status}`);
  }
  return corpo;
}

function postJson(corpo) {
  return { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpo) };
}

function dadosDo(form) {
  return Object.fromEntries(new FormData(form).entries());
}

async function entrar(email, password) {
  const resposta = await api('/api/v1/auth/login', postJson({ email, password }));
  token = resposta.accessToken;
  sessionStorage.setItem(CHAVE_TOKEN, token);
  mostrarPainel();
}

function sair() {
  token = null;
  sessionStorage.removeItem(CHAVE_TOKEN);
  clearInterval(atualizacao);
  el('painel').hidden = true;
  el('acesso').hidden = false;
  el('sair').hidden = true;
}

function mostrarPainel() {
  el('acesso').hidden = true;
  el('painel').hidden = false;
  el('sair').hidden = false;
  carregarVideos();
  clearInterval(atualizacao);
  atualizacao = setInterval(carregarVideos, 3000);
}

function celula(texto) {
  const td = document.createElement('td');
  td.textContent = texto;
  return td;
}

function linha(video) {
  const tr = document.createElement('tr');
  tr.append(celula(video.originalFilename));

  const status = celula(video.status);
  status.className = `status status-${video.status.toLowerCase()}`;
  if (video.errorMessage) status.title = video.errorMessage;
  tr.append(status);

  tr.append(celula(video.frameCount ?? '—'));
  tr.append(celula(new Date(video.createdAt).toLocaleString('pt-BR')));

  const acoes = document.createElement('td');
  if (video.status === 'COMPLETED') {
    const botao = document.createElement('button');
    botao.textContent = 'Baixar ZIP';
    botao.addEventListener('click', () => baixar(video.id));
    acoes.append(botao);
  } else if (video.status === 'FAILED') {
    acoes.textContent = video.errorCode;
  }
  tr.append(acoes);
  return tr;
}

function listaVazia() {
  const tr = document.createElement('tr');
  const td = celula('Nenhum vídeo ainda.');
  td.colSpan = 5;
  tr.append(td);
  return tr;
}

async function carregarVideos() {
  try {
    const pagina = await api('/api/v1/videos?size=50');
    const linhas = pagina.items.length ? pagina.items.map(linha) : [listaVazia()];
    el('lista').replaceChildren(...linhas);
  } catch (erro) {
    mostrarMensagem(erro.message, true);
  }
}

async function baixar(id) {
  try {
    const link = await api(`/api/v1/videos/${id}/download`);
    window.location.href = link.url;
  } catch (erro) {
    mostrarMensagem(erro.message, true);
  }
}

el('form-login').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const { email, password } = dadosDo(evento.target);
  try {
    await entrar(email, password);
    mostrarMensagem('');
  } catch (erro) {
    mostrarMensagem(erro.message, true);
  }
});

el('form-cadastro').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const dados = dadosDo(evento.target);
  try {
    await api('/api/v1/auth/register', postJson(dados));
    await entrar(dados.email, dados.password);
    mostrarMensagem('Conta criada.');
  } catch (erro) {
    mostrarMensagem(erro.message, true);
  }
});

el('form-upload').addEventListener('submit', async (evento) => {
  evento.preventDefault();
  const form = evento.target;
  try {
    await api('/api/v1/videos', { method: 'POST', body: new FormData(form) });
    form.reset();
    mostrarMensagem('Vídeo recebido. O status atualiza sozinho.');
    carregarVideos();
  } catch (erro) {
    mostrarMensagem(erro.message, true);
  }
});

el('sair').addEventListener('click', sair);

if (token) mostrarPainel();
```

`src/main/resources/static/styles.css`:
```css
:root {
  --fundo: #f4f5f7;
  --cartao: #ffffff;
  --texto: #1f2430;
  --suave: #5b6272;
  --primaria: #c8102e;
  --borda: #dde0e6;
  --ok: #1e7d3a;
  --erro: #b3261e;
  --pendente: #8a6d00;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  background: var(--fundo);
  color: var(--texto);
}

.topo {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 16px;
  padding: 16px 24px;
  background: var(--texto);
  color: #fff;
}

.topo h1 { margin: 0; color: var(--primaria); letter-spacing: 0.04em; }
.topo p { margin: 4px 0 0; color: #c9ccd3; }

main { max-width: 960px; margin: 24px auto; padding: 0 16px; }

.cartao {
  background: var(--cartao);
  border: 1px solid var(--borda);
  border-radius: 8px;
  padding: 20px;
  margin-bottom: 16px;
}

h2 { margin-top: 0; font-size: 1.1rem; }

form { display: grid; gap: 12px; max-width: 420px; }
label { display: grid; gap: 4px; font-size: 0.9rem; color: var(--suave); }
input { padding: 8px 10px; border: 1px solid var(--borda); border-radius: 6px; font: inherit; }

button {
  padding: 8px 14px;
  border: 0;
  border-radius: 6px;
  background: var(--primaria);
  color: #fff;
  font: inherit;
  cursor: pointer;
}
button.secundario { background: transparent; border: 1px solid #fff; }

details { margin-top: 16px; }
summary { cursor: pointer; color: var(--suave); margin-bottom: 12px; }

.dica { color: var(--suave); font-size: 0.85rem; margin-bottom: 0; }

.tabela { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 8px; border-bottom: 1px solid var(--borda); }

.status { font-weight: 600; }
.status-completed { color: var(--ok); }
.status-failed { color: var(--erro); }
.status-pending, .status-processing { color: var(--pendente); }

#mensagem.ok { color: var(--ok); }
#mensagem.erro { color: var(--erro); }
```

- [ ] **Step 4: Rodar a suíte**

Run: `./mvnw verify`
Expected: PASS — inclusive os 2 testes de `UiTest`.

- [ ] **Step 5: Escrever `Dockerfile`, `.dockerignore` e `README.md`**

`Dockerfile` (contexto: o próprio diretório do gateway; não usa o fiapx-contracts):
```dockerfile
# syntax=docker/dockerfile:1
FROM maven:3.9-eclipse-temurin-21-alpine AS build
WORKDIR /app
COPY pom.xml ./
RUN mvn -B -q dependency:go-offline || true
COPY src ./src
RUN mvn -B -q package -DskipTests

FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S fiapx && adduser -S fiapx -G fiapx
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
USER fiapx
EXPOSE 8080
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75"
HEALTHCHECK --interval=10s --timeout=3s --start-period=40s --retries=5 \
  CMD wget -qO- http://localhost:8080/actuator/health/readiness | grep -q UP || exit 1
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

`.dockerignore`:
```
.git
target
*.md
```

`README.md`:
```markdown
# fiapx-gateway

Porta de entrada do FIAP X (Spring Cloud Gateway):

- serve a UI em `/`;
- roteia `/api/v1/auth/**` e `/.well-known/**` para o auth-service e
  `/api/v1/videos/**` para o video-api;
- valida o JWT antes de rotear (cada serviço revalida o mesmo token);
- limita o login a 10 tentativas por minuto por IP (`429` em problem+json).

## Rodar os testes

    ./mvnw verify

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `AUTH_SERVICE_URL` | `http://localhost:8081` | Destino das rotas de autenticação |
| `VIDEO_API_URL` | `http://localhost:8082` | Destino das rotas de vídeo |
| `JWKS_URI` | `http://localhost:8081/.well-known/jwks.json` | Chave pública do JWT |
```

- [ ] **Step 6: Adicionar o gateway ao `docker-compose.yml`**

No `docker-compose.yml` da raiz, antes de `volumes:`:
```yaml
  gateway:
    build:
      context: ./services/fiapx-gateway
    image: fiapx/gateway:local
    depends_on:
      auth-service: { condition: service_healthy }
      video-api: { condition: service_healthy }
    environment:
      AUTH_SERVICE_URL: http://auth-service:8081
      VIDEO_API_URL: http://video-api:8082
      JWKS_URI: http://auth-service:8081/.well-known/jwks.json
    ports: ["8080:8080"]
```

- [ ] **Step 7: Subir e rodar o E2E através do gateway**

```bash
docker compose up --build -d --wait --wait-timeout 420
cd e2e && ./mvnw -B test -Dauth.url=http://localhost:8080 -Dvideo.url=http://localhost:8080
```
Expected: 6 testes verdes passando pelo gateway. Em http://localhost:8080 a UI permite cadastrar, entrar, enviar um vídeo, ver o status mudar para `COMPLETED` e baixar o ZIP.

- [ ] **Step 8: Commit no `fiapx-gateway` e publicação**

```bash
cd services/fiapx-gateway
git add -A
git commit -m "feat: UI estatica servida pelo gateway e imagem Docker

Cadastro, login, upload, listagem com atualizacao a cada 3 s e download
do ZIP pela URL assinada."
gh repo create celiovetrano/fiapx-gateway --public --source . \
  --remote origin --push --description "FIAP X - Hackathon POSTECH SOAT Fase 5"
```

- [ ] **Step 9: Commit no `fiapx-infra`**

```bash
git add docker-compose.yml
git commit -m "feat: gateway com UI no ambiente local

A UI fica em http://localhost:8080 e o E2E tambem roda atraves dele."
git push
```

---

## Parte C — CI (D4, noite)

### Task 10: CI reutilizável nos sete repositórios

**Files:**
- Create: `.github/workflows/maven-service.yml` (fiapx-infra)
- Create: `.github/workflows/e2e.yml` (fiapx-infra)
- Create: `.github/workflows/ci.yml` em cada um dos seis repositórios de serviço
- Modify: bit de executável do `mvnw` em todos os repositórios e do `e2e/mvnw`
- Modify: `docs/superpowers/specs/2026-09-10-fiapx-microservices-design.md` (distribuição do contracts)

**Interfaces:**
- Consumes: os seis repositórios publicados (Plano 1 e Tasks 6 e 9).
- Produces: `celiovetrano/fiapx-infra/.github/workflows/maven-service.yml@main` com os inputs `service` (obrigatório), `needs-contracts`, `needs-ffmpeg`, `build-image` e `docker-context`. O CD da Fase 3 reaproveita o mesmo layout `services/<repo>`.

- [ ] **Step 1: Escrever o workflow reutilizável**

`.github/workflows/maven-service.yml`:
```yaml
# Workflow reutilizável: build, testes, gate de cobertura, imagem Docker e Trivy.
# Cada repositório de serviço tem um ci.yml de poucas linhas que chama este arquivo.
name: maven-service

on:
  workflow_call:
    inputs:
      service:
        description: Nome do repositório do serviço (ex. fiapx-video-api)
        required: true
        type: string
      needs-contracts:
        description: Instala o fiapx-contracts no ~/.m2 antes do build
        type: boolean
        default: false
      needs-ffmpeg:
        description: Instala o ffmpeg (testes do worker)
        type: boolean
        default: false
      build-image:
        description: Constrói a imagem e roda o Trivy
        type: boolean
        default: true
      docker-context:
        description: Contexto do docker build. Vazio = services/<service>
        type: string
        default: ""

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      # Layout igual ao da máquina de desenvolvimento: services/<repo>. Os Dockerfiles
      # do video-api, do worker e do notification-service usam services/ como contexto.
      - name: Checkout do serviço
        uses: actions/checkout@v7
        with:
          path: services/${{ inputs.service }}

      - name: Checkout do fiapx-contracts
        if: ${{ inputs.needs-contracts }}
        uses: actions/checkout@v7
        with:
          repository: celiovetrano/fiapx-contracts
          path: services/fiapx-contracts

      - name: Java 21
        uses: actions/setup-java@v6
        with:
          distribution: temurin
          java-version: "21"
          cache: maven
          cache-dependency-path: services/${{ inputs.service }}/pom.xml

      - name: ffmpeg
        if: ${{ inputs.needs-ffmpeg }}
        run: sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg

      - name: Instalar fiapx-contracts no ~/.m2
        if: ${{ inputs.needs-contracts }}
        working-directory: services/fiapx-contracts
        run: ./mvnw -B -q install -DskipTests

      - name: Build, testes e gate de cobertura (JaCoCo 80%)
        working-directory: services/${{ inputs.service }}
        run: ./mvnw -B verify

      - name: Relatórios de teste e cobertura
        if: ${{ always() }}
        uses: actions/upload-artifact@v7
        with:
          name: relatorios-${{ inputs.service }}
          path: |
            services/${{ inputs.service }}/target/surefire-reports/
            services/${{ inputs.service }}/target/site/jacoco/
          if-no-files-found: ignore

      - name: Imagem Docker
        if: ${{ inputs.build-image }}
        env:
          SERVICE: ${{ inputs.service }}
          CONTEXT: ${{ inputs.docker-context }}
        run: docker build -f "services/$SERVICE/Dockerfile" -t "fiapx/$SERVICE:ci" "${CONTEXT:-services/$SERVICE}"

      - name: Trivy (falha em HIGH/CRITICAL com correção disponível)
        if: ${{ inputs.build-image }}
        uses: aquasecurity/trivy-action@0.36.0
        with:
          image-ref: fiapx/${{ inputs.service }}:ci
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"
          format: table
```

- [ ] **Step 2: Escrever o workflow de E2E**

`.github/workflows/e2e.yml`:
```yaml
# Sobe o ambiente completo (Compose + LocalStack + Mailpit) e roda a suíte de ponta a
# ponta duas vezes: direto nos serviços e através do gateway.
name: e2e

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  e2e:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - name: Checkout do fiapx-infra
        uses: actions/checkout@v7

      - name: Checkout do fiapx-contracts
        uses: actions/checkout@v7
        with:
          repository: celiovetrano/fiapx-contracts
          path: services/fiapx-contracts

      - name: Checkout do fiapx-auth-service
        uses: actions/checkout@v7
        with:
          repository: celiovetrano/fiapx-auth-service
          path: services/fiapx-auth-service

      - name: Checkout do fiapx-video-api
        uses: actions/checkout@v7
        with:
          repository: celiovetrano/fiapx-video-api
          path: services/fiapx-video-api

      - name: Checkout do fiapx-processing-worker
        uses: actions/checkout@v7
        with:
          repository: celiovetrano/fiapx-processing-worker
          path: services/fiapx-processing-worker

      - name: Checkout do fiapx-notification-service
        uses: actions/checkout@v7
        with:
          repository: celiovetrano/fiapx-notification-service
          path: services/fiapx-notification-service

      - name: Checkout do fiapx-gateway
        uses: actions/checkout@v7
        with:
          repository: celiovetrano/fiapx-gateway
          path: services/fiapx-gateway

      - name: Java 21
        uses: actions/setup-java@v6
        with:
          distribution: temurin
          java-version: "21"
          cache: maven
          cache-dependency-path: e2e/pom.xml

      - name: Subir o ambiente
        run: docker compose up --build -d --wait --wait-timeout 600

      - name: E2E direto nos serviços
        working-directory: e2e
        run: ./mvnw -B test

      - name: E2E através do gateway
        working-directory: e2e
        run: ./mvnw -B test -Dauth.url=http://localhost:8080 -Dvideo.url=http://localhost:8080

      - name: Logs do Compose
        if: ${{ failure() }}
        run: docker compose logs --no-color > compose.log

      - name: Anexar logs
        if: ${{ failure() }}
        uses: actions/upload-artifact@v7
        with:
          name: compose-logs
          path: compose.log

      - name: Derrubar o ambiente
        if: ${{ always() }}
        run: docker compose down -v
```

> A segunda passada do E2E passa pelo gateway, que limita o login a 10 por minuto por IP.
> A suíte faz 6 logins; se um dia passar de 10, aumente `fiapx.gateway.login-rate-limit.max-attempts`
> no serviço `gateway` do Compose (`FIAPX_GATEWAY_LOGINRATELIMIT_MAXATTEMPTS`).

- [ ] **Step 3: Validar os workflows com o actionlint**

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/repo" -w /repo rhysd/actionlint:latest \
  -color=false .github/workflows/maven-service.yml .github/workflows/e2e.yml
```
Expected: nenhuma saída e código de retorno 0.

- [ ] **Step 4: Registrar o `mvnw` como executável e publicar o `fiapx-infra`**

```bash
git add .github/workflows
git update-index --chmod=+x e2e/mvnw
git commit -m "ci: workflow reutilizavel dos servicos e E2E no GitHub Actions

maven-service.yml faz build, testes, gate do JaCoCo, imagem e Trivy com o
mesmo layout services/<repo> da maquina de desenvolvimento. e2e.yml sobe o
Compose e roda a suite direto nos servicos e atraves do gateway."
git push
```

- [ ] **Step 5: Adicionar o `ci.yml` a cada repositório de serviço**

Em cada repositório, crie `.github/workflows/ci.yml` com o bloco `with:` da tabela e faça o commit junto com o bit de executável do `mvnw`:

```yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:

jobs:
  ci:
    uses: celiovetrano/fiapx-infra/.github/workflows/maven-service.yml@main
    with:
      service: fiapx-video-api
      needs-contracts: true
      docker-context: services
```

| Repositório | `with:` |
|---|---|
| `fiapx-contracts` | `service: fiapx-contracts` · `build-image: false` |
| `fiapx-auth-service` | `service: fiapx-auth-service` |
| `fiapx-video-api` | `service: fiapx-video-api` · `needs-contracts: true` · `docker-context: services` |
| `fiapx-processing-worker` | `service: fiapx-processing-worker` · `needs-contracts: true` · `needs-ffmpeg: true` · `docker-context: services` |
| `fiapx-notification-service` | `service: fiapx-notification-service` · `needs-contracts: true` · `docker-context: services` |
| `fiapx-gateway` | `service: fiapx-gateway` |

Para cada repositório (exemplo com o worker):
```bash
cd services/fiapx-processing-worker
mkdir -p .github/workflows
# escrever .github/workflows/ci.yml com o bloco da tabela
git add .github/workflows/ci.yml
git update-index --chmod=+x mvnw
git commit -m "ci: pipeline de build, testes, cobertura, imagem e Trivy

Chama o workflow reutilizavel do fiapx-infra. O mvnw passa a ser
executavel no git: o Windows o registrava como 100644 e o ./mvnw falhava
no runner Linux."
git push
```

- [ ] **Step 6: Acompanhar os pipelines**

```bash
for r in fiapx-contracts fiapx-auth-service fiapx-video-api fiapx-processing-worker \
         fiapx-notification-service fiapx-gateway; do
  id=$(gh run list --repo celiovetrano/$r --workflow ci --limit 1 --json databaseId --jq '.[0].databaseId')
  gh run watch "$id" --repo celiovetrano/$r --exit-status > /dev/null && echo "$r: verde" || echo "$r: FALHOU"
done
id=$(gh run list --repo celiovetrano/fiapx-infra --workflow e2e --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$id" --repo celiovetrano/fiapx-infra --exit-status > /dev/null && echo "e2e: verde"
```
Expected: os seis `ci` e o `e2e` verdes.

Se o **Trivy** falhar, `gh run view <id> --repo <repo> --log-failed` mostra o pacote e a CVE:
- se a CVE é da imagem base (`eclipse-temurin:21-jre-alpine` ou `apk`), refaça o build: a tag é atualizada com frequência e o `ignore-unfixed` só barra o que já tem correção publicada;
- se é de uma dependência Java, suba a versão no `pom.xml` (ou fixe a propriedade de versão gerenciada pelo Boot) e rode `./mvnw verify` localmente antes de reenviar.

- [ ] **Step 7: Registrar na spec a distribuição do `fiapx-contracts`**

Em `docs/superpowers/specs/2026-09-10-fiapx-microservices-design.md`, na tabela da seção 4, troque a linha do `fiapx-contracts` por:
```markdown
| `fiapx-contracts` | Eventos e DTOs compartilhados; versionado por semver. O CI e os Dockerfiles o instalam no repositório Maven local a partir do código-fonte (checkout do repositório público), sem registry de pacotes |
```
e, na seção 13, troque a frase "`fiapx-contracts` publica no GitHub Packages a cada tag `v*`." por:
```markdown
`fiapx-contracts` roda o mesmo workflow (sem imagem). Os serviços que dependem dele fazem
checkout do repositório público e `./mvnw install` antes do build, o que evita autenticar
um registry de pacotes em cada pipeline.
```

```bash
git add docs/superpowers/specs
git commit -m "docs: contracts distribuido por checkout no CI, sem GitHub Packages"
git push
```

---

## Parte D — AWS (D5)

### Task 11: Serviços prontos para IRSA

Na AWS os pods não têm chaves: as credenciais vêm da role IRSA pela cadeia padrão do SDK. Hoje o `video-api` e o worker têm `test` como credencial padrão e o presigner monta credenciais a partir de `@Value`, o que anularia o IRSA.

**Files:**
- Modify: `services/fiapx-video-api/pom.xml` — `software.amazon.awssdk:sts`
- Modify: `services/fiapx-video-api/src/main/resources/application.yml` — credenciais com padrão vazio
- Modify: `services/fiapx-video-api/src/main/java/br/com/fiapx/video/infrastructure/config/AwsConfig.java`
- Test: `services/fiapx-video-api/src/test/java/br/com/fiapx/video/infrastructure/config/AwsConfigTest.java`
- Modify: `services/fiapx-processing-worker/pom.xml` e `src/main/resources/application.yml`

**Interfaces:**
- Consumes: beans `AwsCredentialsProvider` e `AwsRegionProvider` do spring-cloud-aws.
- Produces: `AwsConfig.s3Presigner(AwsCredentialsProvider, AwsRegionProvider, String endpoint, String publicEndpoint)` → `S3Presigner`.

- [ ] **Step 1: Escrever o teste do presigner (falha)**

`services/fiapx-video-api/src/test/java/br/com/fiapx/video/infrastructure/config/AwsConfigTest.java`:
```java
package br.com.fiapx.video.infrastructure.config;

import org.junit.jupiter.api.Test;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

import java.net.URL;
import java.time.Duration;

import static org.assertj.core.api.Assertions.assertThat;

class AwsConfigTest {

    private final AwsCredentialsProvider credenciais =
            StaticCredentialsProvider.create(AwsBasicCredentials.create("test", "test"));

    private URL assinar(String endpoint, String enderecoPublico) {
        try (S3Presigner presigner = new AwsConfig()
                .s3Presigner(credenciais, () -> Region.US_EAST_1, endpoint, enderecoPublico)) {
            return presigner.presignGetObject(r -> r
                    .signatureDuration(Duration.ofMinutes(15))
                    .getObjectRequest(g -> g.bucket("fiapx-videos").key("processed/u/v.zip")))
                    .url();
        }
    }

    @Test
    void naAwsRealUsaOEndpointPadraoDoS3() {
        URL url = assinar("", "");

        assertThat(url.getHost()).startsWith("fiapx-videos.s3").endsWith(".amazonaws.com");
        assertThat(url.getQuery()).contains("X-Amz-Signature");
    }

    @Test
    void noLocalStackUsaPathStyleNoEndpointDoSdk() {
        URL url = assinar("http://localstack:4566", "");

        assertThat(url.getHost()).isEqualTo("localstack");
        assertThat(url.getPort()).isEqualTo(4566);
        assertThat(url.getPath()).isEqualTo("/fiapx-videos/processed/u/v.zip");
    }

    @Test
    void enderecoPublicoTemPrioridadeSobreOEndpointDoSdk() {
        URL url = assinar("http://localstack:4566", "http://localhost:4566");

        assertThat(url.getHost()).isEqualTo("localhost");
        assertThat(url.getPath()).startsWith("/fiapx-videos/");
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run (em `services/fiapx-video-api`): `./mvnw test -Dtest='*AwsConfigTest'`
Expected: FAIL na compilação — `s3Presigner` ainda recebe região, endpoint e chaves como `String`.

- [ ] **Step 3: Reescrever o `AwsConfig` do video-api**

```java
package br.com.fiapx.video.infrastructure.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.regions.providers.AwsRegionProvider;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

import java.net.URI;

@Configuration
public class AwsConfig {

    /**
     * Presigner com as mesmas credenciais e região do spring-cloud-aws: chaves estáticas
     * quando configuradas (LocalStack), cadeia padrão do SDK caso contrário (IRSA no EKS).
     * A URL vai para o navegador, então usa o endpoint público quando ele existe
     * (no Compose, "localhost:4566" em vez de "localstack:4566").
     */
    @Bean
    S3Presigner s3Presigner(AwsCredentialsProvider credentialsProvider,
                            AwsRegionProvider regionProvider,
                            @Value("${spring.cloud.aws.endpoint:}") String endpoint,
                            @Value("${fiapx.s3.public-endpoint:}") String publicEndpoint) {
        S3Presigner.Builder builder = S3Presigner.builder()
                .region(regionProvider.getRegion())
                .credentialsProvider(credentialsProvider);

        String presignEndpoint = !publicEndpoint.isBlank() ? publicEndpoint : endpoint;
        if (!presignEndpoint.isBlank()) {
            builder.endpointOverride(URI.create(presignEndpoint))
                   .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(true).build());
        }
        return builder.build();
    }
}
```

- [ ] **Step 4: Credenciais com padrão vazio e STS no video-api e no worker**

Nos dois `application.yml`, dentro de `spring.cloud.aws.credentials`, troque:
```yaml
    access-key: ${AWS_ACCESS_KEY_ID:test}
    secret-key: ${AWS_SECRET_ACCESS_KEY:test}
```
por:
```yaml
    # Vazio = cadeia padrão do SDK (IRSA no EKS). No Compose vêm do ambiente.
    access-key: ${AWS_ACCESS_KEY_ID:}
    secret-key: ${AWS_SECRET_ACCESS_KEY:}
```

Nos dois `pom.xml`, logo abaixo da dependência `software.amazon.awssdk:s3`:
```xml
        <!-- Sem o STS no classpath a cadeia padrão do SDK não resolve IRSA no EKS. -->
        <dependency>
            <groupId>software.amazon.awssdk</groupId>
            <artifactId>sts</artifactId>
            <scope>runtime</scope>
        </dependency>
```

- [ ] **Step 5: Rodar as suítes**

```bash
cd services/fiapx-video-api && ./mvnw -B verify
export PATH="$(cygpath -u "$HOME")/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe/ffmpeg-9.0.1-full_build/bin:$PATH"
cd ../fiapx-processing-worker && ./mvnw -B verify
```
Expected: as duas suítes verdes, com o gate do JaCoCo; no video-api entram os 3 testes do `AwsConfigTest`. Os ITs continuam passando porque o `LocalStackTestContainer` fornece as chaves.

- [ ] **Step 6: Confirmar que o Compose continua funcionando**

```bash
docker compose up --build -d --wait --wait-timeout 420
cd e2e && ./mvnw -B test && ./mvnw -B test -Dauth.url=http://localhost:8080 -Dvideo.url=http://localhost:8080
```
Expected: 6 + 6 testes verdes. No Compose as chaves `test` chegam pelas variáveis de ambiente.

- [ ] **Step 7: Commits**

```bash
cd services/fiapx-video-api
git add -A
git commit -m "feat: credenciais AWS via cadeia padrao do SDK para suportar IRSA

O presigner passa a usar o AwsCredentialsProvider e o AwsRegionProvider do
spring-cloud-aws, e as chaves tem padrao vazio. O STS entra no classpath,
sem o qual o SDK nao assume a role IRSA no EKS."
git push

cd ../fiapx-processing-worker
git add -A
git commit -m "feat: credenciais AWS via cadeia padrao do SDK para suportar IRSA"
git push
```
Expected: o `ci` dos dois repositórios fica verde.

---

### Task 12: Terraform — estado remoto, rede, EKS, dados, mensageria e IRSA

Todo o código desta tarefa foi validado com `terraform init -backend=false` + `terraform validate` + `terraform fmt -check` (Terraform 1.9, provider AWS 5.100). Nenhum recurso é criado aqui: o `apply` é a Task 15.

**Files (todos no fiapx-infra):**
- Create: `terraform/bootstrap/main.tf`
- Create: `terraform/{versions,providers,variables,main,secrets,outputs}.tf`, `terraform/terraform.tfvars.example`
- Create: `terraform/modules/{network,eks,rds,storage,messaging,email,ecr,iam}/main.tf`
- Create: `.github/workflows/terraform.yml`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nomes de filas, tópico e serviços do Plano 1 e das Tasks 1-9.
- Produces — outputs usados pelo `scripts/deploy-eks.sh` (Task 14): `region`, `cluster_name`, `ecr_registry`, `ecr_repository_urls`, `db_address`, `db_password_secret`, `jwt_secret`, `bucket_name`, `notification_email`, `irsa_role_arns`. Roles IRSA nomeadas `<serviço>-irsa` para `fiapx-video-api`, `fiapx-processing-worker` e `fiapx-notification-service`, confiando no ServiceAccount `fiapx:<serviço>`.

- [ ] **Step 1: Bootstrap do estado remoto**

`terraform/bootstrap/main.tf`:
```hcl
# Cria o bucket S3 e a tabela DynamoDB que guardam o estado do Terraform principal.
# Roda uma única vez, com estado local:
#   terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  bucket        = "fiapx-tfstate-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "locks" {
  name         = "fiapx-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# Conteúdo pronto para terraform/backend.hcl.
output "backend_config" {
  value = <<-EOT
    bucket         = "${aws_s3_bucket.state.bucket}"
    key            = "fiapx/terraform.tfstate"
    region         = "${var.region}"
    dynamodb_table = "${aws_dynamodb_table.locks.name}"
    encrypt        = true
  EOT
}
```

- [ ] **Step 2: Raiz — versões, provider, variáveis, composição, segredos e outputs**

`terraform/versions.tf`:
```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    # O módulo eks 20.x exige o provider AWS >= 5.95 e < 6.0.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Configurado no init: terraform init -backend-config=backend.hcl
  backend "s3" {}
}
```

`terraform/providers.tf`:
```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "fiapx"
      ManagedBy = "terraform"
    }
  }
}
```

`terraform/variables.tf`:
```hcl
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
```

`terraform/main.tf`:
```hcl
data "aws_caller_identity" "current" {}

locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id
  namespace  = "fiapx"
  services = [
    "fiapx-auth-service",
    "fiapx-video-api",
    "fiapx-processing-worker",
    "fiapx-notification-service",
    "fiapx-gateway",
  ]
}

module "network" {
  source = "./modules/network"
  name   = local.name
}

module "eks" {
  source             = "./modules/eks"
  name               = local.name
  kubernetes_version = var.eks_version
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.private_subnet_ids
  instance_type      = var.node_instance_type
  desired_size       = var.node_desired_size
}

module "rds" {
  source                     = "./modules/rds"
  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
  instance_class             = var.db_instance_class
}

module "storage" {
  source = "./modules/storage"
  # Nome de bucket é global na AWS: o sufixo com a conta evita colisão.
  bucket_name = "${local.name}-videos-${local.account_id}"
}

module "messaging" {
  source = "./modules/messaging"
}

module "email" {
  source             = "./modules/email"
  notification_email = var.notification_email
}

module "ecr" {
  source       = "./modules/ecr"
  repositories = local.services
}

module "iam" {
  source                 = "./modules/iam"
  namespace              = local.namespace
  oidc_provider_arn      = module.eks.oidc_provider_arn
  bucket_arn             = module.storage.bucket_arn
  processing_queue_arn   = module.messaging.processing_queue_arn
  status_queue_arn       = module.messaging.status_queue_arn
  notification_queue_arn = module.messaging.notification_queue_arn
  events_topic_arn       = module.messaging.events_topic_arn
}
```

`terraform/secrets.tf`:
```hcl
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
```

`terraform/outputs.tf`:
```hcl
output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "ecr_registry" {
  value = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "db_address" {
  value = module.rds.address
}

output "db_password_secret" {
  value = module.rds.password_secret_name
}

output "jwt_secret" {
  value = aws_secretsmanager_secret.jwt.name
}

output "bucket_name" {
  value = module.storage.bucket_name
}

output "notification_email" {
  value = var.notification_email
}

output "irsa_role_arns" {
  value = module.iam.role_arns
}
```

`terraform/terraform.tfvars.example`:
```hcl
# Copie para terraform.tfvars (ignorado pelo git) e ajuste.
notification_email = "seu-email@exemplo.com"
# eks_version        = "1.35"
# node_instance_type = "t3.medium"
```

- [ ] **Step 3: Módulos de rede e EKS**

`terraform/modules/network/main.tf`:
```hcl
variable "name" {
  type = string
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = var.name
  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  # Um NAT só, numa AZ: suficiente para o hackathon e ~US$ 1/dia mais barato por AZ.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Tags que o EKS usa para escolher onde criar os load balancers.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}
```

`terraform/modules/eks/main.tf`:
```hcl
variable "name" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "instance_type" {
  type = string
}

variable "desired_size" {
  type = number
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = var.name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      # A partir do Kubernetes 1.33 não existe AMI AL2: o node group precisa ser AL2023.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.instance_type]
      min_size       = var.desired_size
      max_size       = var.desired_size + 1
      desired_size   = var.desired_size
    }
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}
```

- [ ] **Step 4: Módulos de dados — RDS e S3**

`terraform/modules/rds/main.tf`:
```hcl
variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_security_group_ids" {
  type = list(string)
}

variable "instance_class" {
  type = string
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "db" {
  name   = "${var.name}-db"
  vpc_id = var.vpc_id

  ingress {
    description     = "PostgreSQL a partir dos nodes do EKS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }
}

# Uma instância, três bancos (auth_db, video_db, notification_db): database per service
# sem pagar três instâncias. Os bancos são criados pelo scripts/deploy-eks.sh.
resource "aws_db_instance" "this" {
  identifier             = "${var.name}-db"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.instance_class
  allocated_storage      = 20
  storage_encrypted      = true
  username               = "fiapx"
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false
  skip_final_snapshot    = true
  deletion_protection    = false
  apply_immediately      = true
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.name}/db-password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db.result
}

output "address" {
  value = aws_db_instance.this.address
}

output "password_secret_name" {
  value = aws_secretsmanager_secret.db_password.name
}
```

`terraform/modules/storage/main.tf`:
```hcl
variable "bucket_name" {
  type = string
}

resource "aws_s3_bucket" "videos" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "videos" {
  bucket                  = aws_s3_bucket.videos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "videos" {
  bucket = aws_s3_bucket.videos.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# O vídeo original só é necessário até o processamento terminar.
resource "aws_s3_bucket_lifecycle_configuration" "videos" {
  bucket = aws_s3_bucket.videos.id

  rule {
    id     = "apagar-raw-apos-7-dias"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    expiration {
      days = 7
    }
  }
}

output "bucket_name" {
  value = aws_s3_bucket.videos.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.videos.arn
}
```

- [ ] **Step 5: Módulos de mensageria, e-mail e ECR**

`terraform/modules/messaging/main.tf`:
```hcl
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
```

`terraform/modules/email/main.tf`:
```hcl
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
```

`terraform/modules/ecr/main.tf`:
```hcl
variable "repositories" {
  type = list(string)
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(var.repositories)
  name                 = each.value
  image_tag_mutability = "MUTABLE"
  # Permite o terraform destroy mesmo com imagens no repositório.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "repository_urls" {
  value = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}
```

- [ ] **Step 6: Módulo IAM — roles IRSA de menor privilégio**

`terraform/modules/iam/main.tf`:
```hcl
variable "namespace" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "bucket_arn" {
  type = string
}

variable "processing_queue_arn" {
  type = string
}

variable "status_queue_arn" {
  type = string
}

variable "notification_queue_arn" {
  type = string
}

variable "events_topic_arn" {
  type = string
}

locals {
  consume = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:ChangeMessageVisibility",
    "sqs:GetQueueUrl",
    "sqs:GetQueueAttributes",
  ]

  # Menor privilégio por serviço. Chave = nome do ServiceAccount (e da release Helm).
  # auth-service e gateway não acessam a AWS e não recebem role.
  policies = {
    "fiapx-video-api" = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:GetObject"]
          Resource = ["${var.bucket_arn}/raw/*", "${var.bucket_arn}/processed/*"]
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
          Resource = [var.processing_queue_arn]
        },
        {
          Effect   = "Allow"
          Action   = local.consume
          Resource = [var.status_queue_arn]
        },
      ]
    })

    "fiapx-processing-worker" = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = ["${var.bucket_arn}/raw/*"]
        },
        {
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = ["${var.bucket_arn}/processed/*"]
        },
        {
          Effect   = "Allow"
          Action   = local.consume
          Resource = [var.processing_queue_arn]
        },
        {
          # O SnsTemplate resolve o ARN pelo nome chamando CreateTopic (idempotente).
          Effect   = "Allow"
          Action   = ["sns:Publish", "sns:CreateTopic"]
          Resource = [var.events_topic_arn]
        },
      ]
    })

    "fiapx-notification-service" = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = local.consume
          Resource = [var.notification_queue_arn]
        },
        {
          Effect   = "Allow"
          Action   = ["ses:SendEmail", "ses:SendRawEmail"]
          Resource = ["*"]
        },
      ]
    })
  }
}

resource "aws_iam_policy" "service" {
  for_each = local.policies
  name     = "${each.key}-policy"
  policy   = each.value
}

module "irsa" {
  source   = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version  = "5.60.0"
  for_each = local.policies

  role_name = "${each.key}-irsa"
  role_policy_arns = {
    service = aws_iam_policy.service[each.key].arn
  }

  oidc_providers = {
    eks = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.namespace}:${each.key}"]
    }
  }
}

output "role_arns" {
  value = { for name, role in module.irsa : name => role.iam_role_arn }
}
```

- [ ] **Step 7: Ignorar arquivos locais do Terraform**

No `.gitignore`, na seção `# Terraform (fase 2)`, acrescente:
```gitignore
terraform/backend.hcl
terraform/terraform.tfvars
*.tfplan
```
(`.terraform/`, `*.tfstate` e `*.tfstate.*` já estão lá. O `.terraform.lock.hcl` **é** versionado.)

- [ ] **Step 8: Validar sem credenciais AWS**

```bash
export MSYS_NO_PATHCONV=1
TF="$(pwd -W)\\terraform"
docker run --rm -v "$TF:/tf" -w /tf hashicorp/terraform:1.9 init -backend=false -input=false
docker run --rm -v "$TF:/tf" -w /tf hashicorp/terraform:1.9 validate
docker run --rm -v "$TF:/tf" -w /tf hashicorp/terraform:1.9 fmt -check -recursive
docker run --rm -v "$TF\\bootstrap:/tf" -w /tf hashicorp/terraform:1.9 init -backend=false -input=false
docker run --rm -v "$TF\\bootstrap:/tf" -w /tf hashicorp/terraform:1.9 validate
```
Expected: os módulos `vpc` 5.21.0, `eks` 20.37.2 e `iam` 5.60.0 baixam; `Success! The configuration is valid.` na raiz e no bootstrap; `fmt` sem saída.

- [ ] **Step 9: Workflow de validação no CI**

`.github/workflows/terraform.yml`:
```yaml
# Formatação e validação do Terraform, sem credenciais AWS. O plan/apply com OIDC
# entra no Plano 3, junto com o CD.
name: terraform

on:
  push:
    branches: [main]
    paths: ["terraform/**"]
  pull_request:
    paths: ["terraform/**"]

jobs:
  validate:
    runs-on: ubuntu-latest
    container: hashicorp/terraform:1.9
    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: terraform fmt
        run: terraform -chdir=terraform fmt -check -recursive

      - name: terraform validate (raiz)
        run: |
          terraform -chdir=terraform init -backend=false -input=false
          terraform -chdir=terraform validate

      - name: terraform validate (bootstrap)
        run: |
          terraform -chdir=terraform/bootstrap init -backend=false -input=false
          terraform -chdir=terraform/bootstrap validate
```

- [ ] **Step 10: Commit**

```bash
git add terraform .github/workflows/terraform.yml .gitignore
git commit -m "feat: infraestrutura AWS em Terraform

Bootstrap do estado remoto (S3 + DynamoDB), VPC com um NAT, EKS 1.35 com
node group AL2023, RDS PostgreSQL com tres bancos, bucket com lifecycle de
raw/, filas com DLQ assinadas no SNS, identidade SES, ECR por servico e
roles IRSA de menor privilegio. Chave do JWT e senha do banco no Secrets
Manager. Validado com terraform validate e fmt no CI."
git push
```
Expected: o workflow `terraform` fica verde.

---

### Task 13: Chart Helm genérico e valores por serviço

Um chart para os cinco serviços (a spec pede isso para não multiplicar trabalho por sete). O nome da release é o nome do serviço: vira o nome do Deployment, do Service (DNS interno, ex. `http://fiapx-auth-service:8081`) e do ServiceAccount que a role IRSA confia. Validado com `helm lint`, `helm template` e `kubeconform` (15 manifests válidos).

**Files (fiapx-infra):**
- Create: `helm/fiapx-service/Chart.yaml`, `helm/fiapx-service/values.yaml`
- Create: `helm/fiapx-service/templates/{_helpers.tpl,serviceaccount.yaml,service.yaml,deployment.yaml}`
- Create: `helm/values/{fiapx-auth-service,fiapx-video-api,fiapx-processing-worker,fiapx-notification-service,fiapx-gateway}.yaml`

**Interfaces:**
- Consumes: portas e variáveis de ambiente dos serviços; secrets `fiapx-db` (chave `password`) e `fiapx-jwt` (chave `private-key`) criados pela Task 14.
- Produces: valores sobrescritos pelo deploy — `image.repository`, `image.tag`, `serviceAccount.roleArn`, `env.DB_URL`, `env.S3_BUCKET`, `env.NOTIFICATION_FROM`.

- [ ] **Step 1: Chart e valores padrão**

`helm/fiapx-service/Chart.yaml`:
```yaml
apiVersion: v2
name: fiapx-service
description: Chart genérico dos microsserviços Spring Boot do FIAP X
type: application
version: 0.1.0
appVersion: "1.0.0"
```

`helm/fiapx-service/values.yaml`:
```yaml
# Valores padrão. Cada serviço sobrescreve em helm/values/<serviço>.yaml, e o
# scripts/deploy-eks.sh injeta o que só se conhece depois do terraform apply
# (imagem, host do banco, bucket, role IRSA).
replicaCount: 1

image:
  repository: ""
  tag: latest
  pullPolicy: IfNotPresent

containerPort: 8080

service:
  type: ClusterIP
  port: 8080

serviceAccount:
  # ARN da role IRSA. Vazio = sem acesso à AWS (auth-service e gateway).
  roleArn: ""

# Variáveis de ambiente literais: NOME: valor
env: {}

# Variáveis vindas de Secret: [{ name, secretName, key }]
secretEnv: []

resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    memory: 768Mi

terminationGracePeriodSeconds: 30

# Volume de trabalho do worker (vídeo baixado, frames e ZIP).
workDir:
  enabled: false
  mountPath: /tmp/fiapx
  sizeLimit: 2Gi
```

- [ ] **Step 2: Templates**

`helm/fiapx-service/templates/_helpers.tpl`:
```yaml
{{/* O nome da release é o nome do serviço: vira nome do Deployment, do Service
     (DNS interno) e do ServiceAccount usado pela role IRSA. */}}
{{- define "fiapx-service.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fiapx-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fiapx-service.name" . }}
{{- end -}}

{{- define "fiapx-service.labels" -}}
{{ include "fiapx-service.selectorLabels" . }}
app.kubernetes.io/part-of: fiapx
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
```

`helm/fiapx-service/templates/serviceaccount.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "fiapx-service.name" . }}
  labels:
    {{- include "fiapx-service.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.roleArn }}
  annotations:
    eks.amazonaws.com/role-arn: {{ . | quote }}
  {{- end }}
```

`helm/fiapx-service/templates/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "fiapx-service.name" . }}
  labels:
    {{- include "fiapx-service.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "fiapx-service.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
```

`helm/fiapx-service/templates/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "fiapx-service.name" . }}
  labels:
    {{- include "fiapx-service.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "fiapx-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "fiapx-service.selectorLabels" . | nindent 8 }}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: /actuator/prometheus
        prometheus.io/port: {{ .Values.containerPort | quote }}
    spec:
      serviceAccountName: {{ include "fiapx-service.name" . }}
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
      containers:
        - name: app
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.containerPort }}
          {{- if or .Values.env .Values.secretEnv }}
          env:
            {{- range $name, $value := .Values.env }}
            - name: {{ $name }}
              value: {{ $value | quote }}
            {{- end }}
            {{- range .Values.secretEnv }}
            - name: {{ .name }}
              valueFrom:
                secretKeyRef:
                  name: {{ .secretName }}
                  key: {{ .key }}
            {{- end }}
          {{- end }}
          # A JVM leva ~20 s para subir: o startupProbe segura liveness e readiness até lá.
          startupProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 5
            failureThreshold: 36
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: http
            periodSeconds: 5
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          {{- if .Values.workDir.enabled }}
          volumeMounts:
            - name: work
              mountPath: {{ .Values.workDir.mountPath }}
          {{- end }}
      {{- if .Values.workDir.enabled }}
      volumes:
        - name: work
          emptyDir:
            sizeLimit: {{ .Values.workDir.sizeLimit }}
      {{- end }}
```

- [ ] **Step 3: Valores por serviço**

`helm/values/fiapx-auth-service.yaml`:
```yaml
replicaCount: 2
containerPort: 8081
service:
  port: 8081
env:
  DB_USER: fiapx
  # DB_URL é injetado pelo deploy-eks.sh (host do RDS vem do terraform output).
secretEnv:
  - name: DB_PASSWORD
    secretName: fiapx-db
    key: password
  # Mesma chave nas duas réplicas: sem ela cada pod geraria uma chave efêmera diferente.
  - name: JWT_PRIVATE_KEY_PEM
    secretName: fiapx-jwt
    key: private-key
```

`helm/values/fiapx-video-api.yaml`:
```yaml
replicaCount: 2
containerPort: 8082
service:
  port: 8082
env:
  DB_USER: fiapx
  JWKS_URI: http://fiapx-auth-service:8081/.well-known/jwks.json
  AWS_REGION: us-east-1
  SQS_PROCESSING_QUEUE: video-processing-queue
  SQS_STATUS_QUEUE: video-status-queue
  # DB_URL e S3_BUCKET são injetados pelo deploy-eks.sh.
secretEnv:
  - name: DB_PASSWORD
    secretName: fiapx-db
    key: password
```

`helm/values/fiapx-processing-worker.yaml`:
```yaml
replicaCount: 2
containerPort: 8083
service:
  port: 8083
env:
  AWS_REGION: us-east-1
  SQS_PROCESSING_QUEUE: video-processing-queue
  SNS_EVENTS_TOPIC: video-events
  WORK_DIR: /tmp/fiapx
  # S3_BUCKET é injetado pelo deploy-eks.sh.
# Termina o vídeo em curso antes de sair (ffmpeg tem timeout de 600 s).
terminationGracePeriodSeconds: 900
resources:
  requests:
    cpu: 500m
    memory: 768Mi
  limits:
    memory: 1Gi
workDir:
  enabled: true
```

`helm/values/fiapx-notification-service.yaml`:
```yaml
replicaCount: 1
containerPort: 8084
service:
  port: 8084
env:
  DB_USER: fiapx
  AWS_REGION: us-east-1
  SQS_NOTIFICATION_QUEUE: notification-queue
  NOTIFICATION_PROVIDER: ses
  # DB_URL e NOTIFICATION_FROM são injetados pelo deploy-eks.sh.
secretEnv:
  - name: DB_PASSWORD
    secretName: fiapx-db
    key: password
```

`helm/values/fiapx-gateway.yaml`:
```yaml
replicaCount: 2
containerPort: 8080
service:
  # Único serviço exposto: o EKS cria um load balancer da AWS para ele.
  type: LoadBalancer
  port: 80
env:
  AUTH_SERVICE_URL: http://fiapx-auth-service:8081
  VIDEO_API_URL: http://fiapx-video-api:8082
  JWKS_URI: http://fiapx-auth-service:8081/.well-known/jwks.json
```

- [ ] **Step 4: Validar o chart**

```bash
export MSYS_NO_PATHCONV=1
H="$(pwd -W)\\helm"
docker run --rm -v "$H:/h" -w /h alpine/helm:3.16.2 lint fiapx-service -f values/fiapx-processing-worker.yaml
for s in fiapx-auth-service fiapx-video-api fiapx-processing-worker fiapx-notification-service fiapx-gateway; do
  docker run --rm -v "$H:/h" -w /h alpine/helm:3.16.2 template "$s" fiapx-service -f "values/$s.yaml" \
    --set image.repository=123456789012.dkr.ecr.us-east-1.amazonaws.com/$s --set image.tag=t1 \
    --set serviceAccount.roleArn=arn:aws:iam::123456789012:role/x \
    --set env.DB_URL=jdbc:postgresql://db:5432/x
done > /tmp/fiapx-manifests.yaml
docker run --rm -i ghcr.io/yannh/kubeconform:latest-alpine -strict -summary \
  -kubernetes-version 1.31.0 - < /tmp/fiapx-manifests.yaml
```
Expected: `1 chart(s) linted, 0 chart(s) failed` e `Summary: 15 resources found ... Valid: 15, Invalid: 0`.

- [ ] **Step 5: Commit**

```bash
git add helm
git commit -m "feat: chart Helm generico dos servicos e valores por servico

Um chart para os cinco servicos: startup/liveness/readiness pelo actuator,
ServiceAccount com a role IRSA, segredos por secretKeyRef, emptyDir e 900 s
de grace period no worker, LoadBalancer so no gateway."
git push
```

---

### Task 14: Script de deploy no EKS e documentação de operação

**Files (fiapx-infra):**
- Create: `scripts/deploy-eks.sh`
- Modify: `README.md` — seções "Deploy na AWS" e "Destruir tudo"

**Interfaces:**
- Consumes: outputs do Terraform (Task 12); chart e valores (Task 13); Dockerfiles dos cinco serviços em `services/`.
- Produces: `./scripts/deploy-eks.sh` (variável opcional `TAG`); imprime o hostname do load balancer do gateway.

- [ ] **Step 1: Escrever o script**

`scripts/deploy-eks.sh`:
```bash
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
```

> O RDS PostgreSQL 16 exige SSL por padrão (`rds.force_ssl=1`). O `psql` e o driver JDBC
> usam `sslmode=prefer` por padrão, então a conexão já sai criptografada sem configuração extra.

- [ ] **Step 2: Validar com o shellcheck**

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W)\\scripts:/s" koalaman/shellcheck:stable /s/deploy-eks.sh
```
Expected: nenhuma saída e código de retorno 0.

- [ ] **Step 3: Documentar a operação no `README.md` da raiz**

Acrescente ao final:
````markdown
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
````

- [ ] **Step 4: Commit**

```bash
git add scripts/deploy-eks.sh README.md
git update-index --chmod=+x scripts/deploy-eks.sh
git commit -m "feat: script de deploy no EKS e documentacao de operacao

Publica as cinco imagens no ECR, cria segredos e bancos, instala os
servicos com o chart generico e imprime o endereco do gateway. O README
documenta o bootstrap, o apply, o deploy e o destroy."
git push
```

---

### Task 15: Execução na AWS — checkpoint de ir/não ir do D5

Esta tarefa cria recursos pagos na conta AWS do usuário: **confirme com ele antes do Step 3**.
Os passos que exigem ação humana estão marcados com **(usuário)**.

**Interfaces:**
- Consumes: Tasks 11-14; conta AWS com alarme de orçamento de US$ 30 (D1).
- Produces: sistema completo respondendo no load balancer do gateway, ou a decisão registrada de gravar no Compose.

- [ ] **Step 1: Conferir as ferramentas (usuário instala o que faltar)**

```bash
aws --version && terraform -version && kubectl version --client && helm version && docker --version
aws sts get-caller-identity --query Account --output text
```
Expected: todas as ferramentas respondem e o `sts` imprime o id da conta.

- [ ] **Step 2: Bootstrap do estado remoto**

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply -auto-approve
terraform -chdir=terraform/bootstrap output -raw backend_config > terraform/backend.hcl
cat terraform/backend.hcl
```
Expected: bucket `fiapx-tfstate-<conta>` e tabela `fiapx-terraform-locks` criados; `backend.hcl` com os cinco campos.

- [ ] **Step 3: Aplicar a infraestrutura**

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# (usuário) ajustar notification_email em terraform/terraform.tfvars
terraform -chdir=terraform init -backend-config=backend.hcl
terraform -chdir=terraform plan -out=fiapx.tfplan
terraform -chdir=terraform apply fiapx.tfplan
terraform -chdir=terraform output
```
Expected: `Apply complete!` em 15-25 min e os outputs preenchidos (`cluster_name = "fiapx"`, `db_address`, `bucket_name = "fiapx-videos-<conta>"`, três ARNs em `irsa_role_arns`).

- [ ] **Step 4: Verificar o remetente no SES (usuário)**

Clique no link do e-mail "Amazon Web Services – Email Address Verification Request" e confira:
```bash
aws ses get-identity-verification-attributes --identities "$(terraform -chdir=terraform output -raw notification_email)"
```
Expected: `"VerificationStatus": "Success"`.

- [ ] **Step 5: Publicar e instalar os serviços**

```bash
./scripts/deploy-eks.sh
kubectl -n fiapx get pods
```
Expected: os cinco `helm upgrade` terminam sem timeout; 9 pods `Running` e `1/1 Ready` (2 auth, 2 video-api, 2 worker, 1 notification, 2 gateway); o script imprime o hostname do load balancer.

- [ ] **Step 6: Teste de fumaça e E2E contra a AWS**

```bash
LB="$(kubectl -n fiapx get svc fiapx-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
curl -s -o /dev/null -w "UI: %{http_code}\n" "http://$LB/"
cd e2e && ./mvnw -B test -Dauth.url="http://$LB" -Dvideo.url="http://$LB" -Dmailpit.url=
```
Expected: `UI: 200`; 5 testes verdes e 1 pulado (o de e-mail, sem Mailpit). O download do ZIP no E2E vem por URL assinada do S3 real.

Se algum pod não ficar pronto: `kubectl -n fiapx describe pod <pod>` e `kubectl -n fiapx logs <pod>`. Os erros mais prováveis e a causa:
- `AccessDenied` no S3/SQS/SNS → o ServiceAccount não tem a anotação `eks.amazonaws.com/role-arn`, ou o `sts` falta no classpath (Task 11);
- `FATAL: database "..." does not exist` → o passo de bancos do script falhou; rode o trecho `kubectl run fiapx-create-dbs` de novo;
- `ImagePullBackOff` → a tag do `helm upgrade` não corresponde à que foi enviada ao ECR.

- [ ] **Step 7: RF-05 na AWS (usuário)**

Na UI (`http://$LB/`), cadastre-se com o **mesmo e-mail** do `notification_email`, envie um arquivo `.mp4` corrompido e confira: o vídeo termina em `FAILED` e o e-mail "FIAP X: não conseguimos processar o seu vídeo" chega à caixa de entrada.

- [ ] **Step 8: Checkpoint de ir/não ir (20h do D5)**

- **Ir:** Steps 5-7 verdes → o Plano 3 (CD, observabilidade, KEDA, carga) usa o EKS.
- **Não ir:** se às 20h o cluster não estiver servindo os serviços, a gravação usa o Compose (corte 6 da spec §19). O Terraform e o chart continuam entregues, validados no CI, e o EKS entra no vídeo como "próximos passos".

Em ambos os casos, registre a decisão no `README.md` do fiapx-infra e faça o commit. Se o cluster ficar sem uso até o D6, destrua-o (seção "Destruir tudo") e recrie no dia da gravação: o custo cai para as horas efetivamente usadas.

---

## Critérios de conclusão da Fase 2

- [ ] `./mvnw verify` verde no `fiapx-notification-service` e no `fiapx-gateway`, com o gate do JaCoCo.
- [ ] `docker compose up --build` sobe 9 serviços (postgres, localstack, mailpit, auth, video-api, 2 workers, notification, gateway) sem credencial AWS real.
- [ ] E2E com 6 testes verdes direto nos serviços **e** através do gateway; o e-mail de falha aparece no Mailpit (RF-05).
- [ ] A UI em `http://localhost:8080` permite cadastro, login, upload, acompanhamento do status e download.
- [ ] Os workflows `ci` dos seis repositórios, o `e2e` e o `terraform` do fiapx-infra estão verdes no GitHub Actions, com Trivy sem HIGH/CRITICAL corrigíveis.
- [ ] `terraform validate`, `helm lint` + `kubeconform` e `shellcheck` passam.
- [ ] Checkpoint do D5 decidido e registrado: sistema no EKS respondendo pelo load balancer, ou gravação no Compose.

