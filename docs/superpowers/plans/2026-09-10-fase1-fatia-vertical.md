# FIAP X — Fase 1: Fatia Vertical Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar login, upload, processamento assíncrono de vídeo e download do ZIP de frames rodando de ponta a ponta em Docker Compose + LocalStack, com testes automatizados.

**Architecture:** Três serviços Spring Boot em Clean Architecture (`auth-service`, `video-api`, `processing-worker`) mais uma biblioteca de contratos. O `video-api` recebe o upload, grava no S3, persiste `PENDING` e publica na fila SQS respondendo `202 Accepted`; o worker consome a fila, executa ffmpeg, compacta e publica o resultado no SNS; o `video-api` consome o evento de resultado e atualiza o status. Nenhum serviço chama outro por HTTP no caminho de processamento.

**Tech Stack:** Java 21 · Spring Boot 3.3.5 · Maven 3.9 (wrapper `mvnw`) · Spring Cloud AWS 3.2.1 (SQS/SNS/S3) · PostgreSQL 16 + Flyway · Spring Security OAuth2 Resource Server + Nimbus JOSE · JUnit 5 + AssertJ + Mockito · Testcontainers 1.21.4 (PostgreSQL + LocalStack) · JaCoCo 0.8.12 · Docker Compose.

**Spec:** `docs/superpowers/specs/2026-09-10-fiapx-microservices-design.md`

## Global Constraints

Estas regras valem para **todas** as tarefas deste plano.

- **Java 21** (`<java.version>21</java.version>` nos serviços; `maven.compiler.release` nos projetos sem o parent do Spring Boot), **Spring Boot 3.3.5** (`spring-boot-starter-parent`), **Maven 3.9** via wrapper (`./mvnw` no Git Bash, `mvnw.cmd` no PowerShell).
- Testes `*IT` rodam no **Surefire** junto com os unitários (não no Failsafe): `./mvnw test` executa a suíte inteira, `./mvnw test -Dtest=NomeDoTeste` roda um teste específico e `./mvnw verify` acrescenta a verificação de cobertura do JaCoCo.
- Raiz de pacote: `br.com.fiapx.<serviço>` — `contracts`, `auth`, `video`, `worker`.
- **Clean Architecture obrigatória** em cada serviço: `domain` (sem nenhum import de Spring, JPA, AWS ou Jackson) ← `application` (use cases e ports) ← `infrastructure` (adapters). Dependências apontam apenas para dentro.
- **Cobertura JaCoCo mínima de 80% de linha** sobre `..domain..` e `..application..`; o build falha abaixo disso. `..infrastructure.config..` e DTOs ficam excluídos da contagem.
- Extensões de vídeo aceitas, exatamente: `mp4`, `avi`, `mov`, `mkv`, `wmv`, `flv`, `webm`.
- Tamanho máximo de upload: **200 MB** (`209715200` bytes).
- Extração de frames: `ffmpeg -i <entrada> -vf fps=1 -y frame_%04d.png` — **1 frame por segundo**, PNG, nomes com 4 dígitos.
- ZIP **flat** (sem diretórios internos), método **deflate**.
- Estados do vídeo: `PENDING`, `PROCESSING`, `COMPLETED`, `FAILED`. Transições permitidas: `PENDING→PROCESSING`, `PENDING→FAILED`, `PROCESSING→COMPLETED`, `PROCESSING→FAILED`. Qualquer outra é ignorada com log de aviso (idempotência).
- `errorCode` é sempre um valor de `br.com.fiapx.contracts.ErrorCode`: `INVALID_FORMAT`, `FFMPEG_FAILURE`, `NO_FRAMES_EXTRACTED`, `STORAGE_FAILURE`, `TIMEOUT`, `UNKNOWN`.
- Erros HTTP seguem **RFC 7807** (`application/problem+json`).
- Acesso a recurso de outro usuário retorna **404**, nunca 403.
- Chaves S3: `raw/{userId}/{videoId}.{ext}` e `processed/{userId}/{videoId}.zip`.
- Portas: `auth-service` 8081, `video-api` 8082, `processing-worker` 8083 (só actuator).
- Nomes de recursos AWS (idênticos no LocalStack e, depois, na AWS real): bucket `fiapx-videos`, fila `video-processing-queue` (DLQ `video-processing-dlq`), tópico `video-events`, filas `video-status-queue` e `notification-queue`.
- Cada tarefa termina em **um commit**. Mensagens no formato Conventional Commits, em português, sem acentos na primeira linha.

## Estrutura de arquivos

O diretório atual (`projeto-fiapx`) passa a ser o repositório **`fiapx-infra`**. Os repositórios de serviço ficam em `services/`, cada um com seu próprio `.git`, e são ignorados pelo `.gitignore` do `fiapx-infra`.

```
projeto-fiapx/                      ← repo fiapx-infra
├── docs/                           ← spec, planos, ADRs (já existe)
├── legacy/                         ← main.go, go.mod, go.sum, Dockerfile originais
├── sql/schema.sql                  ← entregável "script de criação do banco"
├── localstack/init/01-resources.sh
├── docker-compose.yml
├── e2e/                            ← projeto Maven com os testes de ponta a ponta
└── services/                       ← IGNORADO pelo git do fiapx-infra
    ├── fiapx-contracts/
    ├── fiapx-auth-service/
    ├── fiapx-video-api/
    └── fiapx-processing-worker/
```

Dentro de cada serviço:

```
src/main/java/br/com/fiapx/<svc>/
├── domain/            entidades, value objects, exceções de domínio
├── application/
│   ├── port/          interfaces (in/out)
│   └── usecase/       casos de uso
└── infrastructure/
    ├── config/        beans Spring
    ├── persistence/   entidades JPA + adapters de repositório
    ├── messaging/     publishers e listeners
    ├── storage/       adapter S3
    └── web/           controllers, DTOs, handler RFC 7807
```

---

## Task 1: Preparar o workspace e o repositório fiapx-infra

**Files:**
- Create: `legacy/README.md`
- Move: `main.go`, `go.mod`, `go.sum`, `Dockerfile` → `legacy/`
- Modify: `.gitignore`
- Create: `README.md`
- Create: `services/.gitkeep`

**Interfaces:**
- Consumes: nada (primeira tarefa).
- Produces: a estrutura de diretórios usada por todas as tarefas seguintes; `services/` como raiz dos repositórios de serviço.

- [ ] **Step 1: Mover o projeto base para `legacy/`**

```bash
cd "E:/FIAP - Software Architecture/Haka - Fiap Fase 05/projeto-fiapx"
mkdir -p legacy services
git mv main.go go.mod go.sum Dockerfile legacy/ 2>/dev/null || mv main.go go.mod go.sum Dockerfile legacy/
rm -rf __MACOSX uploads outputs temp
touch services/.gitkeep
```

- [ ] **Step 2: Escrever `legacy/README.md`**

```markdown
# Projeto base (referência)

Código apresentado aos investidores, preservado sem alteração para comparação
"antes × depois" na apresentação. **Não é compilado nem executado pelo sistema novo.**

Serve como especificação de comportamento do processamento:

- extração a `fps=1`, PNG no padrão `frame_%04d.png`;
- ZIP flat com deflate;
- extensões aceitas: mp4, avi, mov, mkv, wmv, flv, webm.

Problemas que a nova arquitetura resolve: ffmpeg síncrono dentro da requisição HTTP,
ausência de banco (status vinha de `filepath.Glob` no disco), ausência de autenticação,
de fila, de testes e de CI/CD.
```

- [ ] **Step 3: Atualizar `.gitignore`**

```gitignore
.idea/
__MACOSX/
.DS_Store
*.zip

# Repositórios de serviço têm seu próprio git
/services/*
!/services/.gitkeep

# Maven / Java
target/
!.mvn/wrapper/maven-wrapper.jar

# Terraform (fase 2)
.terraform/
*.tfstate
*.tfstate.*
.env
```

- [ ] **Step 4: Escrever o `README.md` da raiz**

```markdown
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
```

- [ ] **Step 5: Verificar que a estrutura está correta**

Run: `ls -a && ls legacy && git status --short`
Expected: `legacy/` contém os quatro arquivos Go/Docker; `services/` existe; nenhum `.go` na raiz.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: reorganiza workspace como repo fiapx-infra

Move o projeto base para legacy/ como referencia de comportamento e cria
a estrutura de services/ para os repositorios de microsservico."
```

---

## Task 2: Biblioteca `fiapx-contracts`

Contratos de evento compartilhados. Instalada no repositório Maven local (`./mvnw install`, em `~/.m2`) nesta fase; o GitHub Packages entra na fase 2.

**Files:**
- Create: `services/fiapx-contracts/pom.xml`
- Create: `services/fiapx-contracts/{mvnw,mvnw.cmd,.mvn/}` (Maven wrapper, copiado depois para os demais repositórios)
- Create: `services/fiapx-contracts/src/main/java/br/com/fiapx/contracts/EventType.java`
- Create: `services/fiapx-contracts/src/main/java/br/com/fiapx/contracts/ErrorCode.java`
- Create: `services/fiapx-contracts/src/main/java/br/com/fiapx/contracts/EventEnvelope.java`
- Create: `services/fiapx-contracts/src/main/java/br/com/fiapx/contracts/VideoUploadedPayload.java`
- Create: `services/fiapx-contracts/src/main/java/br/com/fiapx/contracts/VideoProcessingStartedPayload.java`
- Create: `services/fiapx-contracts/src/main/java/br/com/fiapx/contracts/VideoProcessedPayload.java`
- Create: `services/fiapx-contracts/src/main/java/br/com/fiapx/contracts/VideoFailedPayload.java`
- Create: `services/fiapx-contracts/src/main/java/br/com/fiapx/contracts/ContractsJson.java`
- Test: `services/fiapx-contracts/src/test/java/br/com/fiapx/contracts/EventEnvelopeTest.java`

**Interfaces:**
- Consumes: nada.
- Produces — usados por **todas** as tarefas seguintes:
  - `EventEnvelope.of(EventType, UUID correlationId, T payload)` → `EventEnvelope<T>`
  - `EventEnvelope<T>` com acessores `eventId()`, `eventType()`, `eventVersion()`, `occurredAt()`, `correlationId()`, `payload()`
  - `ContractsJson.mapper()` → `ObjectMapper` configurado
  - `VideoUploadedPayload(UUID videoId, UUID userId, String userEmail, String s3RawKey, String originalFilename, long sizeBytes)`
  - `VideoProcessingStartedPayload(UUID videoId, UUID userId, String workerId, int attempt)`
  - `VideoProcessedPayload(UUID videoId, UUID userId, String s3ZipKey, int frameCount, long processingMillis)`
  - `VideoFailedPayload(UUID videoId, UUID userId, String userEmail, ErrorCode errorCode, String errorMessage, int attempt)`
  - `ErrorCode` com `INVALID_FORMAT`, `FFMPEG_FAILURE`, `NO_FRAMES_EXTRACTED`, `STORAGE_FAILURE`, `TIMEOUT`, `UNKNOWN`

- [ ] **Step 1: Criar o repositório e o Maven wrapper**

```bash
cd services && mkdir -p fiapx-contracts && cd fiapx-contracts
git init
# Sem Maven instalado: use o binario em cache ~/.m2/wrapper/dists/apache-maven-3.9.12/*/bin/mvn
mvn -N wrapper:wrapper -Dmaven=3.9.12
```

- [ ] **Step 2: Escrever o `pom.xml`**

Biblioteca pura, sem o parent do Spring Boot: os serviços trazem o Jackson gerenciado
pelo Boot, e a versão declarada aqui é compatível com a do Boot 3.3.5.

`pom.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <groupId>br.com.fiapx</groupId>
    <artifactId>fiapx-contracts</artifactId>
    <version>1.0.0</version>
    <packaging>jar</packaging>

    <properties>
        <maven.compiler.release>21</maven.compiler.release>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
        <jackson.version>2.17.2</jackson.version>
    </properties>

    <dependencyManagement>
        <dependencies>
            <dependency>
                <groupId>org.junit</groupId>
                <artifactId>junit-bom</artifactId>
                <version>5.10.3</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
        </dependencies>
    </dependencyManagement>

    <dependencies>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
            <version>${jackson.version}</version>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.datatype</groupId>
            <artifactId>jackson-datatype-jsr310</artifactId>
            <version>${jackson.version}</version>
        </dependency>

        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <version>3.26.3</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-compiler-plugin</artifactId>
                <version>3.13.0</version>
            </plugin>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-surefire-plugin</artifactId>
                <version>3.5.2</version>
            </plugin>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-source-plugin</artifactId>
                <version>3.3.1</version>
                <executions>
                    <execution>
                        <id>attach-sources</id>
                        <goals><goal>jar-no-fork</goal></goals>
                    </execution>
                </executions>
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
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 3: Escrever o teste que falha**

`src/test/java/br/com/fiapx/contracts/EventEnvelopeTest.java`:
```java
package br.com.fiapx.contracts;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class EventEnvelopeTest {

    private final ObjectMapper mapper = ContractsJson.mapper();

    @Test
    void serializaEDesserializaVideoUploaded() throws Exception {
        UUID videoId = UUID.randomUUID();
        var payload = new VideoUploadedPayload(
                videoId, UUID.randomUUID(), "aluno@fiap.com.br",
                "raw/" + UUID.randomUUID() + "/" + videoId + ".mp4", "clip.mp4", 2048L);

        var envelope = EventEnvelope.of(EventType.VIDEO_UPLOADED, videoId, payload);
        String json = mapper.writeValueAsString(envelope);
        var back = mapper.readValue(json, new TypeReference<EventEnvelope<VideoUploadedPayload>>() {});

        assertThat(back.payload()).isEqualTo(payload);
        assertThat(back.eventType()).isEqualTo(EventType.VIDEO_UPLOADED);
        assertThat(back.correlationId()).isEqualTo(videoId);
        assertThat(back.eventVersion()).isEqualTo(1);
        assertThat(back.eventId()).isNotNull();
    }

    @Test
    void eventTypeUsaONomeDeFioEmPascalCase() throws Exception {
        var envelope = EventEnvelope.of(EventType.VIDEO_FAILED, UUID.randomUUID(),
                new VideoFailedPayload(UUID.randomUUID(), UUID.randomUUID(), "a@b.com",
                        ErrorCode.FFMPEG_FAILURE, "codec invalido", 1));

        assertThat(mapper.writeValueAsString(envelope)).contains("\"eventType\":\"VideoFailed\"");
    }

    @Test
    void toleraCampoDesconhecidoParaPermitirMudancaAditiva() throws Exception {
        String json = """
                {"eventId":"%s","eventType":"VideoProcessed","eventVersion":1,
                 "occurredAt":"2026-09-10T14:03:11Z","correlationId":"%s",
                 "campoNovoDeUmaVersaoFutura":"ignorar",
                 "payload":{"videoId":"%s","userId":"%s","s3ZipKey":"processed/a/b.zip",
                            "frameCount":42,"processingMillis":1500,"outroCampoNovo":1}}
                """.formatted(UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID());

        var back = mapper.readValue(json, new TypeReference<EventEnvelope<VideoProcessedPayload>>() {});

        assertThat(back.payload().frameCount()).isEqualTo(42);
        assertThat(back.payload().processingMillis()).isEqualTo(1500L);
    }

    @Test
    void rejeitaEventTypeDesconhecido() {
        String json = """
                {"eventId":"%s","eventType":"VideoTeleportado","eventVersion":1,
                 "occurredAt":"2026-09-10T14:03:11Z","correlationId":"%s","payload":{}}
                """.formatted(UUID.randomUUID(), UUID.randomUUID());

        assertThatThrownBy(() -> mapper.readValue(json, new TypeReference<EventEnvelope<Object>>() {}))
                .hasMessageContaining("VideoTeleportado");
    }
}
```

- [ ] **Step 4: Rodar o teste e confirmar que falha**

Run: `./mvnw test`
Expected: FAIL na compilação — `EventEnvelope`, `EventType`, `ContractsJson` e os payloads não existem.

- [ ] **Step 5: Implementar `EventType` e `ErrorCode`**

`EventType.java`:
```java
package br.com.fiapx.contracts;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonValue;

public enum EventType {
    VIDEO_UPLOADED("VideoUploaded"),
    VIDEO_PROCESSING_STARTED("VideoProcessingStarted"),
    VIDEO_PROCESSED("VideoProcessed"),
    VIDEO_FAILED("VideoFailed");

    private final String wireName;

    EventType(String wireName) {
        this.wireName = wireName;
    }

    @JsonValue
    public String wireName() {
        return wireName;
    }

    @JsonCreator
    public static EventType fromWire(String value) {
        for (EventType type : values()) {
            if (type.wireName.equals(value)) {
                return type;
            }
        }
        throw new IllegalArgumentException("Tipo de evento desconhecido: " + value);
    }
}
```

`ErrorCode.java`:
```java
package br.com.fiapx.contracts;

public enum ErrorCode {
    INVALID_FORMAT,
    FFMPEG_FAILURE,
    NO_FRAMES_EXTRACTED,
    STORAGE_FAILURE,
    TIMEOUT,
    UNKNOWN
}
```

- [ ] **Step 6: Implementar o envelope, os payloads e o mapper**

`EventEnvelope.java`:
```java
package br.com.fiapx.contracts;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.time.Instant;
import java.util.UUID;

@JsonIgnoreProperties(ignoreUnknown = true)
public record EventEnvelope<T>(
        UUID eventId,
        EventType eventType,
        int eventVersion,
        Instant occurredAt,
        UUID correlationId,
        T payload) {

    public static final int CURRENT_VERSION = 1;

    public static <T> EventEnvelope<T> of(EventType eventType, UUID correlationId, T payload) {
        return new EventEnvelope<>(
                UUID.randomUUID(), eventType, CURRENT_VERSION, Instant.now(), correlationId, payload);
    }
}
```

`VideoUploadedPayload.java`:
```java
package br.com.fiapx.contracts;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.util.UUID;

@JsonIgnoreProperties(ignoreUnknown = true)
public record VideoUploadedPayload(
        UUID videoId,
        UUID userId,
        String userEmail,
        String s3RawKey,
        String originalFilename,
        long sizeBytes) {
}
```

`VideoProcessingStartedPayload.java`:
```java
package br.com.fiapx.contracts;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.util.UUID;

@JsonIgnoreProperties(ignoreUnknown = true)
public record VideoProcessingStartedPayload(
        UUID videoId,
        UUID userId,
        String workerId,
        int attempt) {
}
```

`VideoProcessedPayload.java`:
```java
package br.com.fiapx.contracts;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.util.UUID;

@JsonIgnoreProperties(ignoreUnknown = true)
public record VideoProcessedPayload(
        UUID videoId,
        UUID userId,
        String s3ZipKey,
        int frameCount,
        long processingMillis) {
}
```

`VideoFailedPayload.java`:
```java
package br.com.fiapx.contracts;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.util.UUID;

@JsonIgnoreProperties(ignoreUnknown = true)
public record VideoFailedPayload(
        UUID videoId,
        UUID userId,
        String userEmail,
        ErrorCode errorCode,
        String errorMessage,
        int attempt) {
}
```

`ContractsJson.java`:
```java
package br.com.fiapx.contracts;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;

/**
 * Mapper único usado por todos os serviços, para que produtor e consumidor
 * serializem eventos exatamente da mesma forma.
 */
public final class ContractsJson {

    private ContractsJson() {
    }

    public static ObjectMapper mapper() {
        return JsonMapper.builder()
                .addModule(new JavaTimeModule())
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
                .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
                .build();
    }
}
```

- [ ] **Step 7: Rodar os testes e confirmar que passam**

Run: `./mvnw test`
Expected: PASS — 4 testes verdes.

- [ ] **Step 8: Publicar no repositório Maven local**

Run: `./mvnw install`
Expected: `br/com/fiapx/fiapx-contracts/1.0.0/fiapx-contracts-1.0.0.jar` em `~/.m2/repository`.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: contratos de evento compartilhados

Envelope versionado, payloads dos quatro eventos de video e ObjectMapper
comum. Desserializacao tolera campos desconhecidos para permitir mudancas
aditivas sem quebrar consumidores."
```

---

## Task 3: `auth-service` — esqueleto Maven e domínio de usuário

Domínio puro: sem Spring, sem JPA. É aqui que a regra de senha e de e-mail vive.

**Files:**
- Create: `services/fiapx-auth-service/pom.xml`
- Create: `src/main/java/br/com/fiapx/auth/AuthServiceApplication.java`
- Create: `src/main/java/br/com/fiapx/auth/domain/{Email,RawPassword,User}.java`
- Create: `src/main/java/br/com/fiapx/auth/domain/exception/{DomainException,InvalidEmailException,WeakPasswordException,EmailAlreadyRegisteredException,InvalidCredentialsException}.java`
- Test: `src/test/java/br/com/fiapx/auth/domain/{EmailTest,RawPasswordTest,UserTest}.java`

**Interfaces:**
- Consumes: nada de tarefas anteriores.
- Produces:
  - `Email(String value)` — record; normaliza para minúsculas; lança `InvalidEmailException`.
  - `RawPassword(String value)` — record; lança `WeakPasswordException`.
  - `User.register(Email, String passwordHash, String fullName)` → `User`
  - `User.rehydrate(UUID id, Email, String passwordHash, String fullName, boolean enabled, Instant createdAt)` → `User`
  - Acessores de `User`: `id()`, `email()`, `passwordHash()`, `fullName()`, `enabled()`, `createdAt()`

- [ ] **Step 1: Criar o repositório, o Maven wrapper e o `pom.xml`**

```bash
cd services && mkdir -p fiapx-auth-service && cd fiapx-auth-service && git init
cp -r ../fiapx-contracts/mvnw ../fiapx-contracts/mvnw.cmd ../fiapx-contracts/.mvn \
      ../fiapx-contracts/.gitattributes ../fiapx-contracts/.gitignore .
```

`pom.xml`:
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
    <artifactId>fiapx-auth-service</artifactId>
    <version>1.0.0</version>

    <properties>
        <java.version>21</java.version>
        <!-- 1.21.4+: versões anteriores usam uma API do Docker recusada pelo Engine 29 -->
        <testcontainers.version>1.21.4</testcontainers.version>
    </properties>

    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-validation</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-security</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-data-jpa</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-actuator</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.security</groupId>
            <artifactId>spring-security-oauth2-jose</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springdoc</groupId>
            <artifactId>springdoc-openapi-starter-webmvc-ui</artifactId>
            <version>2.6.0</version>
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
            <groupId>org.postgresql</groupId>
            <artifactId>postgresql</artifactId>
            <scope>runtime</scope>
        </dependency>

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.springframework.security</groupId>
            <artifactId>spring-security-test</artifactId>
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
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-testcontainers</artifactId>
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
                                        <include>br.com.fiapx.auth.domain*</include>
                                        <include>br.com.fiapx.auth.application*</include>
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

- [ ] **Step 2: Escrever os testes de domínio (falham)**

`src/test/java/br/com/fiapx/auth/domain/EmailTest.java`:
```java
package br.com.fiapx.auth.domain;

import br.com.fiapx.auth.domain.exception.InvalidEmailException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class EmailTest {

    @Test
    void normalizaParaMinusculas() {
        assertThat(new Email("Aluno@FIAP.com.BR").value()).isEqualTo("aluno@fiap.com.br");
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "  ", "semarroba", "sem@dominio", "com espaco@fiap.com.br", "@fiap.com.br"})
    void rejeitaEmailInvalido(String candidato) {
        assertThatThrownBy(() -> new Email(candidato)).isInstanceOf(InvalidEmailException.class);
    }

    @Test
    void rejeitaNulo() {
        assertThatThrownBy(() -> new Email(null)).isInstanceOf(InvalidEmailException.class);
    }
}
```

`src/test/java/br/com/fiapx/auth/domain/RawPasswordTest.java`:
```java
package br.com.fiapx.auth.domain;

import br.com.fiapx.auth.domain.exception.WeakPasswordException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class RawPasswordTest {

    @Test
    void aceitaSenhaComLetrasNumerosEOitoCaracteres() {
        assertThat(new RawPassword("fiapx2026").value()).isEqualTo("fiapx2026");
    }

    @ParameterizedTest
    @ValueSource(strings = {"curta1", "somenteletras", "12345678"})
    void rejeitaSenhaFraca(String candidata) {
        assertThatThrownBy(() -> new RawPassword(candidata)).isInstanceOf(WeakPasswordException.class);
    }

    @Test
    void naoExpoeASenhaNoToString() {
        assertThat(new RawPassword("fiapx2026").toString()).doesNotContain("fiapx2026");
    }
}
```

`src/test/java/br/com/fiapx/auth/domain/UserTest.java`:
```java
package br.com.fiapx.auth.domain;

import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class UserTest {

    @Test
    void registraUsuarioHabilitadoComIdEDataGerados() {
        var user = User.register(new Email("aluno@fiap.com.br"), "$2a$12$hash", "Aluno FIAP");

        assertThat(user.id()).isNotNull();
        assertThat(user.enabled()).isTrue();
        assertThat(user.createdAt()).isBeforeOrEqualTo(Instant.now());
        assertThat(user.email().value()).isEqualTo("aluno@fiap.com.br");
        assertThat(user.fullName()).isEqualTo("Aluno FIAP");
    }

    @Test
    void rehydratePreservaOsValoresPersistidos() {
        UUID id = UUID.randomUUID();
        Instant criado = Instant.parse("2026-01-01T00:00:00Z");

        var user = User.rehydrate(id, new Email("a@b.com"), "$2a$12$hash", "Nome", false, criado);

        assertThat(user.id()).isEqualTo(id);
        assertThat(user.enabled()).isFalse();
        assertThat(user.createdAt()).isEqualTo(criado);
    }

    @Test
    void naoExpoeOHashNoToString() {
        var user = User.register(new Email("a@b.com"), "$2a$12$segredo", "Nome");
        assertThat(user.toString()).doesNotContain("segredo");
    }
}
```

- [ ] **Step 3: Rodar e confirmar que falham**

Run: `./mvnw test`
Expected: FAIL na compilação — `Email`, `RawPassword`, `User` e as exceções não existem.

- [ ] **Step 4: Implementar as exceções de domínio**

`domain/exception/DomainException.java`:
```java
package br.com.fiapx.auth.domain.exception;

public abstract class DomainException extends RuntimeException {
    protected DomainException(String message) {
        super(message);
    }
}
```

Nos mesmos moldes, cada uma em seu arquivo:
```java
public class InvalidEmailException extends DomainException {
    public InvalidEmailException(String message) { super(message); }
}
public class WeakPasswordException extends DomainException {
    public WeakPasswordException(String message) { super(message); }
}
public class EmailAlreadyRegisteredException extends DomainException {
    public EmailAlreadyRegisteredException(String message) { super(message); }
}
public class InvalidCredentialsException extends DomainException {
    public InvalidCredentialsException() { super("Credenciais invalidas"); }
}
```

- [ ] **Step 5: Implementar `Email`, `RawPassword` e `User`**

`domain/Email.java`:
```java
package br.com.fiapx.auth.domain;

import br.com.fiapx.auth.domain.exception.InvalidEmailException;

import java.util.Locale;
import java.util.regex.Pattern;

public record Email(String value) {

    private static final Pattern PATTERN = Pattern.compile("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$");

    public Email {
        if (value == null || !PATTERN.matcher(value.trim()).matches()) {
            throw new InvalidEmailException("E-mail invalido");
        }
        value = value.trim().toLowerCase(Locale.ROOT);
    }
}
```

`domain/RawPassword.java`:
```java
package br.com.fiapx.auth.domain;

import br.com.fiapx.auth.domain.exception.WeakPasswordException;

public record RawPassword(String value) {

    public static final int MIN_LENGTH = 8;

    public RawPassword {
        if (value == null || value.length() < MIN_LENGTH) {
            throw new WeakPasswordException("A senha deve ter ao menos " + MIN_LENGTH + " caracteres");
        }
        if (value.chars().noneMatch(Character::isLetter) || value.chars().noneMatch(Character::isDigit)) {
            throw new WeakPasswordException("A senha deve conter letras e numeros");
        }
    }

    @Override
    public String toString() {
        return "RawPassword[protegida]";
    }
}
```

`domain/User.java`:
```java
package br.com.fiapx.auth.domain;

import java.time.Instant;
import java.util.Objects;
import java.util.UUID;

public final class User {

    private final UUID id;
    private final Email email;
    private final String passwordHash;
    private final String fullName;
    private final boolean enabled;
    private final Instant createdAt;

    private User(UUID id, Email email, String passwordHash, String fullName,
                 boolean enabled, Instant createdAt) {
        this.id = Objects.requireNonNull(id);
        this.email = Objects.requireNonNull(email);
        this.passwordHash = Objects.requireNonNull(passwordHash);
        this.fullName = Objects.requireNonNull(fullName);
        this.enabled = enabled;
        this.createdAt = Objects.requireNonNull(createdAt);
    }

    public static User register(Email email, String passwordHash, String fullName) {
        return new User(UUID.randomUUID(), email, passwordHash, fullName, true, Instant.now());
    }

    public static User rehydrate(UUID id, Email email, String passwordHash, String fullName,
                                 boolean enabled, Instant createdAt) {
        return new User(id, email, passwordHash, fullName, enabled, createdAt);
    }

    public UUID id() { return id; }
    public Email email() { return email; }
    public String passwordHash() { return passwordHash; }
    public String fullName() { return fullName; }
    public boolean enabled() { return enabled; }
    public Instant createdAt() { return createdAt; }

    @Override
    public String toString() {
        return "User[id=" + id + ", email=" + email.value() + "]";
    }
}
```

`AuthServiceApplication.java`:
```java
package br.com.fiapx.auth;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class AuthServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(AuthServiceApplication.class, args);
    }
}
```

- [ ] **Step 6: Rodar os testes e confirmar que passam**

Run: `./mvnw test`
Expected: PASS — todos os testes de domínio verdes.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: dominio de usuario com regras de e-mail e senha

Value objects Email e RawPassword validam na construcao; User nao expoe
hash em toString. Nenhum import de framework na camada de dominio."
```

---

## Task 4: `auth-service` — persistência com Flyway e Testcontainers

**Files:**
- Create: `src/main/resources/db/migration/V1__create_users.sql`
- Create: `src/main/resources/application.yml`, `application-local.yml`
- Create: `src/main/java/br/com/fiapx/auth/application/port/out/UserRepository.java`
- Create: `src/main/java/br/com/fiapx/auth/infrastructure/persistence/{UserEntity,SpringDataUserRepository,JpaUserRepository}.java`
- Test: `src/test/java/br/com/fiapx/auth/infrastructure/persistence/JpaUserRepositoryIT.java`
- Test: `src/test/java/br/com/fiapx/auth/support/PostgresTestContainer.java`

**Interfaces:**
- Consumes: `User`, `Email` (Task 3).
- Produces:
  - `UserRepository` (port): `void save(User user)`, `Optional<User> findByEmail(Email email)`, `boolean existsByEmail(Email email)`, `Optional<User> findById(UUID id)`

- [ ] **Step 1: Escrever a migration `V1__create_users.sql`**

```sql
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
```

- [ ] **Step 2: Escrever o `application.yml`**

```yaml
server:
  port: 8081

spring:
  application:
    name: fiapx-auth-service
  datasource:
    url: ${DB_URL:jdbc:postgresql://localhost:5432/auth_db}
    username: ${DB_USER:fiapx}
    password: ${DB_PASSWORD:fiapx}
  jpa:
    hibernate:
      ddl-auto: validate
    open-in-view: false
  flyway:
    enabled: true

auth:
  jwt:
    issuer: https://fiapx.local/auth
    ttl-seconds: 3600
    private-key-pem: ${JWT_PRIVATE_KEY_PEM:}

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

- [ ] **Step 3: Escrever o teste de integração (falha)**

`src/test/java/br/com/fiapx/auth/support/PostgresTestContainer.java`:
```java
package br.com.fiapx.auth.support;

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
                .withDatabaseName("auth_db")
                .withUsername("fiapx")
                .withPassword("fiapx");
    }
}
```

`src/test/java/br/com/fiapx/auth/infrastructure/persistence/JpaUserRepositoryIT.java`:
```java
package br.com.fiapx.auth.infrastructure.persistence;

import br.com.fiapx.auth.application.port.out.UserRepository;
import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.User;
import br.com.fiapx.auth.support.PostgresTestContainer;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@Import(PostgresTestContainer.class)
class JpaUserRepositoryIT {

    @Autowired
    UserRepository repository;

    @Test
    void salvaERecuperaPorEmail() {
        var user = User.register(new Email("Aluno@FIAP.com.br"), "$2a$12$hash", "Aluno FIAP");
        repository.save(user);

        var encontrado = repository.findByEmail(new Email("aluno@fiap.com.br"));

        assertThat(encontrado).isPresent();
        assertThat(encontrado.get().id()).isEqualTo(user.id());
        assertThat(encontrado.get().fullName()).isEqualTo("Aluno FIAP");
        assertThat(encontrado.get().enabled()).isTrue();
    }

    @Test
    void existsByEmailIgnoraCaixa() {
        repository.save(User.register(new Email("outro@fiap.com.br"), "$2a$12$hash", "Outro"));

        assertThat(repository.existsByEmail(new Email("OUTRO@fiap.com.br"))).isTrue();
        assertThat(repository.existsByEmail(new Email("inexistente@fiap.com.br"))).isFalse();
    }

    @Test
    void findByEmailVazioQuandoNaoExiste() {
        assertThat(repository.findByEmail(new Email("ninguem@fiap.com.br"))).isEmpty();
    }
}
```

- [ ] **Step 4: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*JpaUserRepositoryIT'`
Expected: FAIL — `UserRepository` não existe.

- [ ] **Step 5: Implementar o port e os adapters**

`application/port/out/UserRepository.java`:
```java
package br.com.fiapx.auth.application.port.out;

import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.User;

import java.util.Optional;
import java.util.UUID;

public interface UserRepository {
    void save(User user);
    Optional<User> findByEmail(Email email);
    boolean existsByEmail(Email email);
    Optional<User> findById(UUID id);
}
```

`infrastructure/persistence/UserEntity.java`:
```java
package br.com.fiapx.auth.infrastructure.persistence;

import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.User;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "users")
class UserEntity {

    @Id
    private UUID id;

    @Column(nullable = false, unique = true)
    private String email;

    @Column(name = "password_hash", nullable = false, length = 60)
    private String passwordHash;

    @Column(name = "full_name", nullable = false, length = 120)
    private String fullName;

    @Column(nullable = false)
    private boolean enabled;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    protected UserEntity() {
    }

    static UserEntity from(User user) {
        UserEntity entity = new UserEntity();
        entity.id = user.id();
        entity.email = user.email().value();
        entity.passwordHash = user.passwordHash();
        entity.fullName = user.fullName();
        entity.enabled = user.enabled();
        entity.createdAt = user.createdAt();
        entity.updatedAt = Instant.now();
        return entity;
    }

    User toDomain() {
        return User.rehydrate(id, new Email(email), passwordHash, fullName, enabled, createdAt);
    }
}
```

`infrastructure/persistence/SpringDataUserRepository.java`:
```java
package br.com.fiapx.auth.infrastructure.persistence;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.Optional;
import java.util.UUID;

interface SpringDataUserRepository extends JpaRepository<UserEntity, UUID> {

    @Query("select u from UserEntity u where lower(u.email) = lower(:email)")
    Optional<UserEntity> findByEmailIgnoringCase(String email);

    @Query("select count(u) > 0 from UserEntity u where lower(u.email) = lower(:email)")
    boolean existsByEmailIgnoringCase(String email);
}
```

`infrastructure/persistence/JpaUserRepository.java`:
```java
package br.com.fiapx.auth.infrastructure.persistence;

import br.com.fiapx.auth.application.port.out.UserRepository;
import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.User;
import org.springframework.stereotype.Repository;

import java.util.Optional;
import java.util.UUID;

@Repository
class JpaUserRepository implements UserRepository {

    private final SpringDataUserRepository delegate;

    JpaUserRepository(SpringDataUserRepository delegate) {
        this.delegate = delegate;
    }

    @Override
    public void save(User user) {
        delegate.save(UserEntity.from(user));
    }

    @Override
    public Optional<User> findByEmail(Email email) {
        return delegate.findByEmailIgnoringCase(email.value()).map(UserEntity::toDomain);
    }

    @Override
    public boolean existsByEmail(Email email) {
        return delegate.existsByEmailIgnoringCase(email.value());
    }

    @Override
    public Optional<User> findById(UUID id) {
        return delegate.findById(id).map(UserEntity::toDomain);
    }
}
```

- [ ] **Step 6: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*JpaUserRepositoryIT'`
Expected: PASS — Testcontainers sobe o PostgreSQL 16, o Flyway aplica `V1` e os três testes ficam verdes.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: persistencia de usuarios com Flyway e adapter JPA

Port UserRepository na camada de aplicacao, UserEntity isolada na
infraestrutura. Testes de integracao com Testcontainers validam a
migration e a busca por e-mail ignorando caixa."
```

---

## Task 5: `auth-service` — cadastro de usuário (use case + endpoint + RFC 7807)

**Files:**
- Create: `src/main/java/br/com/fiapx/auth/application/port/out/PasswordHasher.java`
- Create: `src/main/java/br/com/fiapx/auth/application/usecase/RegisterUserUseCase.java`
- Create: `src/main/java/br/com/fiapx/auth/infrastructure/security/{BCryptPasswordHasher,SecurityConfig}.java`
- Create: `src/main/java/br/com/fiapx/auth/infrastructure/web/{AuthController,RegisterRequest,UserResponse,ApiExceptionHandler}.java`
- Test: `src/test/java/br/com/fiapx/auth/application/usecase/RegisterUserUseCaseTest.java`
- Test: `src/test/java/br/com/fiapx/auth/infrastructure/web/AuthControllerRegisterTest.java`

**Interfaces:**
- Consumes: `User`, `Email`, `RawPassword` (Task 3); `UserRepository` (Task 4).
- Produces:
  - `PasswordHasher` (port): `String hash(RawPassword raw)`, `boolean matches(RawPassword raw, String hash)`
  - `RegisterUserUseCase.execute(String email, String password, String fullName)` → `User`
  - `UserResponse(UUID id, String email, String fullName)` — corpo do `201`

- [ ] **Step 1: Escrever o teste do use case (falha)**

```java
package br.com.fiapx.auth.application.usecase;

import br.com.fiapx.auth.application.port.out.PasswordHasher;
import br.com.fiapx.auth.application.port.out.UserRepository;
import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.RawPassword;
import br.com.fiapx.auth.domain.exception.EmailAlreadyRegisteredException;
import br.com.fiapx.auth.domain.exception.WeakPasswordException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class RegisterUserUseCaseTest {

    private UserRepository repository;
    private PasswordHasher hasher;
    private RegisterUserUseCase useCase;

    @BeforeEach
    void setUp() {
        repository = mock(UserRepository.class);
        hasher = mock(PasswordHasher.class);
        useCase = new RegisterUserUseCase(repository, hasher);
        when(hasher.hash(any(RawPassword.class))).thenReturn("$2a$12$hashfake");
    }

    @Test
    void registraUsuarioNovoGuardandoApenasOHash() {
        when(repository.existsByEmail(new Email("aluno@fiap.com.br"))).thenReturn(false);

        var user = useCase.execute("Aluno@FIAP.com.br", "fiapx2026", "Aluno FIAP");

        assertThat(user.email().value()).isEqualTo("aluno@fiap.com.br");
        assertThat(user.passwordHash()).isEqualTo("$2a$12$hashfake");
        verify(repository).save(user);
    }

    @Test
    void rejeitaEmailJaCadastrado() {
        when(repository.existsByEmail(new Email("aluno@fiap.com.br"))).thenReturn(true);

        assertThatThrownBy(() -> useCase.execute("aluno@fiap.com.br", "fiapx2026", "Aluno"))
                .isInstanceOf(EmailAlreadyRegisteredException.class);

        verify(repository, never()).save(any());
    }

    @Test
    void rejeitaSenhaFracaAntesDeTocarNoRepositorio() {
        assertThatThrownBy(() -> useCase.execute("aluno@fiap.com.br", "123", "Aluno"))
                .isInstanceOf(WeakPasswordException.class);

        verify(repository, never()).save(any());
    }

    @Test
    void naoConsultaORepositorioQuandoOEmailEInvalido() {
        assertThatThrownBy(() -> useCase.execute("semarroba", "fiapx2026", "Aluno"))
                .hasMessageContaining("invalido");

        verify(repository, never()).existsByEmail(any());
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*RegisterUserUseCaseTest'`
Expected: FAIL — `RegisterUserUseCase` e `PasswordHasher` não existem.

- [ ] **Step 3: Implementar o port e o use case**

`application/port/out/PasswordHasher.java`:
```java
package br.com.fiapx.auth.application.port.out;

import br.com.fiapx.auth.domain.RawPassword;

public interface PasswordHasher {
    String hash(RawPassword raw);
    boolean matches(RawPassword raw, String hash);
}
```

`application/usecase/RegisterUserUseCase.java`:
```java
package br.com.fiapx.auth.application.usecase;

import br.com.fiapx.auth.application.port.out.PasswordHasher;
import br.com.fiapx.auth.application.port.out.UserRepository;
import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.RawPassword;
import br.com.fiapx.auth.domain.User;
import br.com.fiapx.auth.domain.exception.EmailAlreadyRegisteredException;
import org.springframework.stereotype.Service;

@Service
public class RegisterUserUseCase {

    private final UserRepository repository;
    private final PasswordHasher hasher;

    public RegisterUserUseCase(UserRepository repository, PasswordHasher hasher) {
        this.repository = repository;
        this.hasher = hasher;
    }

    public User execute(String email, String password, String fullName) {
        Email validEmail = new Email(email);
        RawPassword rawPassword = new RawPassword(password);

        if (repository.existsByEmail(validEmail)) {
            throw new EmailAlreadyRegisteredException("E-mail ja cadastrado");
        }

        User user = User.register(validEmail, hasher.hash(rawPassword), fullName);
        repository.save(user);
        return user;
    }
}
```

> Nota de arquitetura: `@Service` aqui é a única concessão do Spring na camada de
> aplicação, e é aceitável porque não altera o comportamento nem impede o teste
> unitário — repare que o teste acima instancia o use case com `new`.

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*RegisterUserUseCaseTest'`
Expected: PASS — 4 testes verdes.

- [ ] **Step 5: Escrever o teste do endpoint (falha)**

```java
package br.com.fiapx.auth.infrastructure.web;

import br.com.fiapx.auth.application.usecase.RegisterUserUseCase;
import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.User;
import br.com.fiapx.auth.domain.exception.EmailAlreadyRegisteredException;
import br.com.fiapx.auth.infrastructure.security.SecurityConfig;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

// O slice @WebMvcTest não carrega classes @Configuration: sem o import valeria a
// segurança padrão (CSRF ligado) e todo POST responderia 403.
@WebMvcTest(AuthController.class)
@Import(SecurityConfig.class)
class AuthControllerRegisterTest {

    @Autowired
    MockMvc mockMvc;

    @MockBean
    RegisterUserUseCase registerUser;

    @Test
    void retorna201ComOsDadosDoUsuarioCriado() throws Exception {
        var user = User.register(new Email("aluno@fiap.com.br"), "$2a$12$h", "Aluno FIAP");
        when(registerUser.execute(anyString(), anyString(), anyString())).thenReturn(user);

        mockMvc.perform(post("/api/v1/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"email":"aluno@fiap.com.br","password":"fiapx2026","fullName":"Aluno FIAP"}
                                """))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").value(user.id().toString()))
                .andExpect(jsonPath("$.email").value("aluno@fiap.com.br"))
                .andExpect(jsonPath("$.fullName").value("Aluno FIAP"));
    }

    @Test
    void retorna409EmProblemJsonQuandoOEmailJaExiste() throws Exception {
        when(registerUser.execute(anyString(), anyString(), anyString()))
                .thenThrow(new EmailAlreadyRegisteredException("E-mail ja cadastrado"));

        mockMvc.perform(post("/api/v1/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"email":"aluno@fiap.com.br","password":"fiapx2026","fullName":"Aluno"}
                                """))
                .andExpect(status().isConflict())
                .andExpect(content().contentTypeCompatibleWith("application/problem+json"))
                .andExpect(jsonPath("$.title").value("E-mail ja cadastrado"));
    }

    @Test
    void retorna400QuandoOCorpoEInvalido() throws Exception {
        mockMvc.perform(post("/api/v1/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"email":"","password":"","fullName":""}
                                """))
                .andExpect(status().isBadRequest())
                .andExpect(content().contentTypeCompatibleWith("application/problem+json"));
    }
}
```

Adicione o import estático `org.springframework.test.web.servlet.result.MockMvcResultMatchers.content`.

- [ ] **Step 6: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*AuthControllerRegisterTest'`
Expected: FAIL — `AuthController` não existe.

- [ ] **Step 7: Implementar DTOs, controller, handler de erro e `SecurityConfig`**

`infrastructure/web/RegisterRequest.java`:
```java
package br.com.fiapx.auth.infrastructure.web;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record RegisterRequest(
        @NotBlank String email,
        @NotBlank String password,
        @NotBlank @Size(max = 120) String fullName) {
}
```

`infrastructure/web/UserResponse.java`:
```java
package br.com.fiapx.auth.infrastructure.web;

import br.com.fiapx.auth.domain.User;

import java.util.UUID;

public record UserResponse(UUID id, String email, String fullName) {
    static UserResponse from(User user) {
        return new UserResponse(user.id(), user.email().value(), user.fullName());
    }
}
```

`infrastructure/web/AuthController.java` (o endpoint de login entra na Task 6):
```java
package br.com.fiapx.auth.infrastructure.web;

import br.com.fiapx.auth.application.usecase.RegisterUserUseCase;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/auth")
public class AuthController {

    private final RegisterUserUseCase registerUser;

    public AuthController(RegisterUserUseCase registerUser) {
        this.registerUser = registerUser;
    }

    @PostMapping("/register")
    public ResponseEntity<UserResponse> register(@Valid @RequestBody RegisterRequest request) {
        var user = registerUser.execute(request.email(), request.password(), request.fullName());
        return ResponseEntity.status(HttpStatus.CREATED).body(UserResponse.from(user));
    }
}
```

`infrastructure/web/ApiExceptionHandler.java`:
```java
package br.com.fiapx.auth.infrastructure.web;

import br.com.fiapx.auth.domain.exception.EmailAlreadyRegisteredException;
import br.com.fiapx.auth.domain.exception.InvalidCredentialsException;
import br.com.fiapx.auth.domain.exception.InvalidEmailException;
import br.com.fiapx.auth.domain.exception.WeakPasswordException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class ApiExceptionHandler {

    @ExceptionHandler(EmailAlreadyRegisteredException.class)
    ProblemDetail onConflict(EmailAlreadyRegisteredException ex) {
        return problem(HttpStatus.CONFLICT, ex.getMessage());
    }

    @ExceptionHandler({InvalidEmailException.class, WeakPasswordException.class})
    ProblemDetail onBadRequest(RuntimeException ex) {
        return problem(HttpStatus.BAD_REQUEST, ex.getMessage());
    }

    @ExceptionHandler(InvalidCredentialsException.class)
    ProblemDetail onUnauthorized(InvalidCredentialsException ex) {
        return problem(HttpStatus.UNAUTHORIZED, ex.getMessage());
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    ProblemDetail onValidation(MethodArgumentNotValidException ex) {
        String detalhe = ex.getBindingResult().getFieldErrors().stream()
                .map(e -> e.getField() + ": " + e.getDefaultMessage())
                .reduce((a, b) -> a + "; " + b)
                .orElse("Requisicao invalida");
        return problem(HttpStatus.BAD_REQUEST, "Requisicao invalida", detalhe);
    }

    private ProblemDetail problem(HttpStatus status, String title) {
        return problem(status, title, title);
    }

    private ProblemDetail problem(HttpStatus status, String title, String detail) {
        ProblemDetail problem = ProblemDetail.forStatus(status);
        problem.setTitle(title);
        problem.setDetail(detail);
        return problem;
    }
}
```

`infrastructure/security/BCryptPasswordHasher.java`:
```java
package br.com.fiapx.auth.infrastructure.security;

import br.com.fiapx.auth.application.port.out.PasswordHasher;
import br.com.fiapx.auth.domain.RawPassword;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Component;

@Component
class BCryptPasswordHasher implements PasswordHasher {

    private final BCryptPasswordEncoder encoder = new BCryptPasswordEncoder(12);

    @Override
    public String hash(RawPassword raw) {
        return encoder.encode(raw.value());
    }

    @Override
    public boolean matches(RawPassword raw, String hash) {
        return encoder.matches(raw.value(), hash);
    }
}
```

`infrastructure/security/SecurityConfig.java`:
```java
package br.com.fiapx.auth.infrastructure.security;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
public class SecurityConfig {

    @Bean
    SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        return http
                .csrf(csrf -> csrf.disable())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers("/api/v1/auth/register", "/api/v1/auth/login",
                                "/.well-known/**", "/actuator/**",
                                "/swagger-ui/**", "/v3/api-docs/**").permitAll()
                        .anyRequest().authenticated())
                .build();
    }
}
```

- [ ] **Step 8: Rodar a suíte inteira**

Run: `./mvnw test`
Expected: PASS — testes de domínio, do use case, do controller e a integração da Task 4.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: cadastro de usuario com BCrypt e erros em RFC 7807

POST /api/v1/auth/register retorna 201, 409 para e-mail duplicado e 400
para corpo invalido, sempre em application/problem+json."
```

---

## Task 6: `auth-service` — login, JWT RS256 e JWKS

**Files:**
- Create: `src/main/java/br/com/fiapx/auth/application/port/out/TokenIssuer.java`
- Create: `src/main/java/br/com/fiapx/auth/application/AccessToken.java`
- Create: `src/main/java/br/com/fiapx/auth/application/usecase/AuthenticateUserUseCase.java`
- Create: `src/main/java/br/com/fiapx/auth/infrastructure/security/{RsaKeyProvider,NimbusTokenIssuer}.java`
- Create: `src/main/java/br/com/fiapx/auth/infrastructure/web/{JwksController,LoginRequest,TokenResponse}.java`
- Modify: `src/main/java/br/com/fiapx/auth/infrastructure/web/AuthController.java`
- Test: `src/test/java/br/com/fiapx/auth/application/usecase/AuthenticateUserUseCaseTest.java`
- Test: `src/test/java/br/com/fiapx/auth/infrastructure/security/NimbusTokenIssuerTest.java`

**Interfaces:**
- Consumes: `User`, `Email`, `RawPassword`, `PasswordHasher`, `UserRepository`.
- Produces:
  - `AccessToken(String value, long expiresInSeconds)`
  - `TokenIssuer.issue(User user)` → `AccessToken`
  - `AuthenticateUserUseCase.execute(String email, String password)` → `AccessToken`
  - `TokenResponse(String accessToken, String tokenType, long expiresIn)` — corpo do `200`
  - `GET /.well-known/jwks.json` — consumido pelo `video-api` na Task 11

- [ ] **Step 1: Escrever o teste do use case (falha)**

```java
package br.com.fiapx.auth.application.usecase;

import br.com.fiapx.auth.application.AccessToken;
import br.com.fiapx.auth.application.port.out.PasswordHasher;
import br.com.fiapx.auth.application.port.out.TokenIssuer;
import br.com.fiapx.auth.application.port.out.UserRepository;
import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.RawPassword;
import br.com.fiapx.auth.domain.User;
import br.com.fiapx.auth.domain.exception.InvalidCredentialsException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AuthenticateUserUseCaseTest {

    private UserRepository repository;
    private PasswordHasher hasher;
    private TokenIssuer tokenIssuer;
    private AuthenticateUserUseCase useCase;
    private User usuario;

    @BeforeEach
    void setUp() {
        repository = mock(UserRepository.class);
        hasher = mock(PasswordHasher.class);
        tokenIssuer = mock(TokenIssuer.class);
        useCase = new AuthenticateUserUseCase(repository, hasher, tokenIssuer);
        usuario = User.register(new Email("aluno@fiap.com.br"), "$2a$12$hash", "Aluno");
        when(tokenIssuer.issue(any(User.class))).thenReturn(new AccessToken("jwt.token.aqui", 3600));
    }

    @Test
    void emiteTokenQuandoAsCredenciaisConferem() {
        when(repository.findByEmail(new Email("aluno@fiap.com.br"))).thenReturn(Optional.of(usuario));
        when(hasher.matches(any(RawPassword.class), eqHash())).thenReturn(true);

        AccessToken token = useCase.execute("Aluno@FIAP.com.br", "fiapx2026");

        assertThat(token.value()).isEqualTo("jwt.token.aqui");
        assertThat(token.expiresInSeconds()).isEqualTo(3600);
    }

    @Test
    void rejeitaSenhaIncorretaSemRevelarQualCampoFalhou() {
        when(repository.findByEmail(new Email("aluno@fiap.com.br"))).thenReturn(Optional.of(usuario));
        when(hasher.matches(any(RawPassword.class), eqHash())).thenReturn(false);

        assertThatThrownBy(() -> useCase.execute("aluno@fiap.com.br", "senhaerrada1"))
                .isInstanceOf(InvalidCredentialsException.class)
                .hasMessage("Credenciais invalidas");
    }

    @Test
    void rejeitaUsuarioInexistenteComAMesmaMensagem() {
        when(repository.findByEmail(any(Email.class))).thenReturn(Optional.empty());

        assertThatThrownBy(() -> useCase.execute("ninguem@fiap.com.br", "fiapx2026"))
                .isInstanceOf(InvalidCredentialsException.class)
                .hasMessage("Credenciais invalidas");

        verify(tokenIssuer, never()).issue(any());
    }

    @Test
    void rejeitaSenhaMalformadaSemVazarExcecaoDeDominio() {
        assertThatThrownBy(() -> useCase.execute("aluno@fiap.com.br", "curta"))
                .isInstanceOf(InvalidCredentialsException.class);

        verify(repository, never()).findByEmail(any());
    }

    private static String eqHash() {
        return org.mockito.ArgumentMatchers.eq("$2a$12$hash");
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*AuthenticateUserUseCaseTest'`
Expected: FAIL — `AuthenticateUserUseCase`, `TokenIssuer` e `AccessToken` não existem.

- [ ] **Step 3: Implementar `AccessToken`, `TokenIssuer` e o use case**

`application/AccessToken.java`:
```java
package br.com.fiapx.auth.application;

public record AccessToken(String value, long expiresInSeconds) {
}
```

`application/port/out/TokenIssuer.java`:
```java
package br.com.fiapx.auth.application.port.out;

import br.com.fiapx.auth.application.AccessToken;
import br.com.fiapx.auth.domain.User;

public interface TokenIssuer {
    AccessToken issue(User user);
}
```

`application/usecase/AuthenticateUserUseCase.java`:
```java
package br.com.fiapx.auth.application.usecase;

import br.com.fiapx.auth.application.AccessToken;
import br.com.fiapx.auth.application.port.out.PasswordHasher;
import br.com.fiapx.auth.application.port.out.TokenIssuer;
import br.com.fiapx.auth.application.port.out.UserRepository;
import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.RawPassword;
import br.com.fiapx.auth.domain.User;
import br.com.fiapx.auth.domain.exception.DomainException;
import br.com.fiapx.auth.domain.exception.InvalidCredentialsException;
import org.springframework.stereotype.Service;

@Service
public class AuthenticateUserUseCase {

    private final UserRepository repository;
    private final PasswordHasher hasher;
    private final TokenIssuer tokenIssuer;

    public AuthenticateUserUseCase(UserRepository repository, PasswordHasher hasher, TokenIssuer tokenIssuer) {
        this.repository = repository;
        this.hasher = hasher;
        this.tokenIssuer = tokenIssuer;
    }

    public AccessToken execute(String email, String password) {
        Email validEmail;
        RawPassword rawPassword;
        try {
            validEmail = new Email(email);
            rawPassword = new RawPassword(password);
        } catch (DomainException ex) {
            // Entrada malformada não deve revelar se o e-mail existe.
            throw new InvalidCredentialsException();
        }

        User user = repository.findByEmail(validEmail)
                .orElseThrow(InvalidCredentialsException::new);

        if (!user.enabled() || !hasher.matches(rawPassword, user.passwordHash())) {
            throw new InvalidCredentialsException();
        }

        return tokenIssuer.issue(user);
    }
}
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*AuthenticateUserUseCaseTest'`
Expected: PASS — 4 testes verdes.

- [ ] **Step 5: Escrever o teste do emissor de token (falha)**

```java
package br.com.fiapx.auth.infrastructure.security;

import br.com.fiapx.auth.domain.Email;
import br.com.fiapx.auth.domain.User;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.crypto.RSASSAVerifier;
import com.nimbusds.jwt.SignedJWT;
import org.junit.jupiter.api.Test;

import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

class NimbusTokenIssuerTest {

    private final RSAKey chave = new RsaKeyProvider("").rsaKey();
    private final NimbusTokenIssuer issuer =
            new NimbusTokenIssuer(chave, "https://fiapx.local/auth", 3600);

    @Test
    void emiteJwtRs256ComSubEmailEExpiracao() throws Exception {
        var user = User.register(new Email("aluno@fiap.com.br"), "$2a$12$h", "Aluno FIAP");

        var token = issuer.issue(user);
        SignedJWT jwt = SignedJWT.parse(token.value());

        assertThat(jwt.verify(new RSASSAVerifier(chave.toRSAPublicKey()))).isTrue();
        assertThat(jwt.getJWTClaimsSet().getSubject()).isEqualTo(user.id().toString());
        assertThat(jwt.getJWTClaimsSet().getStringClaim("email")).isEqualTo("aluno@fiap.com.br");
        assertThat(jwt.getJWTClaimsSet().getIssuer()).isEqualTo("https://fiapx.local/auth");
        assertThat(jwt.getJWTClaimsSet().getExpirationTime().toInstant())
                .isAfter(Instant.now().plusSeconds(3500));
        assertThat(token.expiresInSeconds()).isEqualTo(3600);
    }

    @Test
    void oJwksExpoeSomenteAChavePublica() {
        String json = issuer.jwks().toString();

        assertThat(json).contains("\"kty\":\"RSA\"").contains("\"n\"").contains("\"e\"");
        assertThat(json).doesNotContain("\"d\"").doesNotContain("\"p\"").doesNotContain("\"q\"");
    }
}
```

- [ ] **Step 6: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*NimbusTokenIssuerTest'`
Expected: FAIL — `RsaKeyProvider` e `NimbusTokenIssuer` não existem.

- [ ] **Step 7: Implementar a chave, o emissor e os endpoints**

`infrastructure/security/RsaKeyProvider.java`:
```java
package br.com.fiapx.auth.infrastructure.security;

import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.security.KeyFactory;
import java.security.interfaces.RSAPrivateCrtKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.Base64;
import java.util.UUID;

/**
 * Na fase 1 a chave é gerada na inicialização quando nenhuma PEM é fornecida.
 * Consequência aceita: reiniciar o serviço invalida os tokens emitidos, e mais de
 * uma réplica emitiria chaves diferentes. A fase 2 move a chave para o AWS Secrets
 * Manager e injeta via JWT_PRIVATE_KEY_PEM.
 */
@Configuration
public class RsaKeyProvider {

    private static final Logger log = LoggerFactory.getLogger(RsaKeyProvider.class);

    private final String privateKeyPem;

    public RsaKeyProvider(@Value("${auth.jwt.private-key-pem:}") String privateKeyPem) {
        this.privateKeyPem = privateKeyPem;
    }

    @Bean
    public RSAKey rsaKey() {
        try {
            if (privateKeyPem == null || privateKeyPem.isBlank()) {
                log.warn("Nenhuma chave RSA configurada: gerando uma chave efemera. "
                        + "Use JWT_PRIVATE_KEY_PEM fora do ambiente local.");
                return new RSAKeyGenerator(2048).keyID(UUID.randomUUID().toString()).generate();
            }
            String base64 = privateKeyPem
                    .replace("-----BEGIN PRIVATE KEY-----", "")
                    .replace("-----END PRIVATE KEY-----", "")
                    .replaceAll("\\s", "");
            var spec = new PKCS8EncodedKeySpec(Base64.getDecoder().decode(base64));
            var privateKey = (RSAPrivateCrtKey) KeyFactory.getInstance("RSA").generatePrivate(spec);
            return new RSAKey.Builder(
                    new com.nimbusds.jose.util.Base64URL(
                            Base64.getUrlEncoder().withoutPadding()
                                    .encodeToString(privateKey.getModulus().toByteArray())),
                    new com.nimbusds.jose.util.Base64URL(
                            Base64.getUrlEncoder().withoutPadding()
                                    .encodeToString(privateKey.getPublicExponent().toByteArray())))
                    .privateKey(privateKey)
                    .keyID("fiapx-auth")
                    .build();
        } catch (Exception ex) {
            throw new IllegalStateException("Falha ao carregar a chave RSA do JWT", ex);
        }
    }
}
```

`infrastructure/security/NimbusTokenIssuer.java`:
```java
package br.com.fiapx.auth.infrastructure.security;

import br.com.fiapx.auth.application.AccessToken;
import br.com.fiapx.auth.application.port.out.TokenIssuer;
import br.com.fiapx.auth.domain.User;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.Date;

@Component
public class NimbusTokenIssuer implements TokenIssuer {

    private final RSAKey rsaKey;
    private final String issuer;
    private final long ttlSeconds;

    public NimbusTokenIssuer(RSAKey rsaKey,
                             @Value("${auth.jwt.issuer}") String issuer,
                             @Value("${auth.jwt.ttl-seconds}") long ttlSeconds) {
        this.rsaKey = rsaKey;
        this.issuer = issuer;
        this.ttlSeconds = ttlSeconds;
    }

    @Override
    public AccessToken issue(User user) {
        try {
            Instant agora = Instant.now();
            var claims = new JWTClaimsSet.Builder()
                    .subject(user.id().toString())
                    .issuer(issuer)
                    .claim("email", user.email().value())
                    .claim("name", user.fullName())
                    .issueTime(Date.from(agora))
                    .expirationTime(Date.from(agora.plusSeconds(ttlSeconds)))
                    .build();

            var jwt = new SignedJWT(
                    new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(rsaKey.getKeyID()).build(), claims);
            jwt.sign(new RSASSASigner(rsaKey));

            return new AccessToken(jwt.serialize(), ttlSeconds);
        } catch (Exception ex) {
            throw new IllegalStateException("Falha ao assinar o token", ex);
        }
    }

    public JWKSet jwks() {
        return new JWKSet(rsaKey.toPublicJWK());
    }
}
```

`infrastructure/web/JwksController.java`:
```java
package br.com.fiapx.auth.infrastructure.web;

import br.com.fiapx.auth.infrastructure.security.NimbusTokenIssuer;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class JwksController {

    private final NimbusTokenIssuer tokenIssuer;

    public JwksController(NimbusTokenIssuer tokenIssuer) {
        this.tokenIssuer = tokenIssuer;
    }

    @GetMapping("/.well-known/jwks.json")
    public Map<String, Object> jwks() {
        return tokenIssuer.jwks().toJSONObject();
    }
}
```

`infrastructure/web/LoginRequest.java` e `TokenResponse.java`:
```java
package br.com.fiapx.auth.infrastructure.web;

import jakarta.validation.constraints.NotBlank;

public record LoginRequest(@NotBlank String email, @NotBlank String password) {
}
```
```java
package br.com.fiapx.auth.infrastructure.web;

import br.com.fiapx.auth.application.AccessToken;

public record TokenResponse(String accessToken, String tokenType, long expiresIn) {
    static TokenResponse from(AccessToken token) {
        return new TokenResponse(token.value(), "Bearer", token.expiresInSeconds());
    }
}
```

Acrescente ao `AuthController` (o construtor passa a receber os dois use cases).
**Atualize também `AuthControllerRegisterTest`** acrescentando o mock que o novo
construtor exige, senão o teste da Task 5 para de subir o contexto:

```java
    @MockBean
    AuthenticateUserUseCase authenticateUser;
```

Trecho a acrescentar no controller:
```java
    private final AuthenticateUserUseCase authenticateUser;

    @PostMapping("/login")
    public TokenResponse login(@Valid @RequestBody LoginRequest request) {
        return TokenResponse.from(authenticateUser.execute(request.email(), request.password()));
    }

    @GetMapping("/me")
    public UserResponse me(@AuthenticationPrincipal Jwt jwt) {
        return new UserResponse(
                UUID.fromString(jwt.getSubject()),
                jwt.getClaimAsString("email"),
                jwt.getClaimAsString("name"));
    }
```

`/me` lê os dados do próprio token, sem consultar o banco — o JWT já carrega
`sub`, `email` e `name`. Importe `GetMapping`, `AuthenticationPrincipal`, `Jwt` e `UUID`.
Para que o endpoint exija token, o `auth-service` precisa validar JWT: acrescente
a dependência `org.springframework.boot:spring-boot-starter-oauth2-resource-server`
ao `pom.xml` e, no `SecurityConfig`, `.oauth2ResourceServer(o -> o.jwt(j -> {}))`
mais a propriedade `spring.security.oauth2.resourceserver.jwt.jwk-set-uri:
http://localhost:8081/.well-known/jwks.json` no `application.yml`.

Teste a acrescentar em `AuthControllerRegisterTest`:

```java
    @Test
    void meDevolveOsDadosDoToken() throws Exception {
        UUID id = UUID.randomUUID();
        mockMvc.perform(get("/api/v1/auth/me")
                        .with(jwt().jwt(j -> j.subject(id.toString())
                                .claim("email", "aluno@fiap.com.br")
                                .claim("name", "Aluno FIAP"))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.email").value("aluno@fiap.com.br"));
    }

    @Test
    void meExigeToken() throws Exception {
        mockMvc.perform(get("/api/v1/auth/me")).andExpect(status().isUnauthorized());
    }
```

- [ ] **Step 8: Rodar a suíte inteira**

Run: `./mvnw verify`
Expected: PASS, incluindo a verificação de cobertura do JaCoCo.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: login com JWT RS256 e endpoint JWKS

Mensagem de erro identica para usuario inexistente, senha errada e entrada
malformada, para nao revelar a existencia da conta. A chave publica fica
disponivel em /.well-known/jwks.json para o video-api validar tokens."
```

---

## Task 7: `auth-service` — Dockerfile multi-stage

**Files:**
- Create: `services/fiapx-auth-service/Dockerfile`
- Create: `services/fiapx-auth-service/.dockerignore`
- Create: `services/fiapx-auth-service/README.md`

**Interfaces:**
- Consumes: o jar produzido por `./mvnw package`.
- Produces: imagem `fiapx/auth-service:local`, usada no `docker-compose.yml` da Task 22.

- [ ] **Step 1: Escrever o `Dockerfile`**

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
EXPOSE 8081
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75"
HEALTHCHECK --interval=10s --timeout=3s --start-period=40s --retries=5 \
  CMD wget -qO- http://localhost:8081/actuator/health/readiness | grep -q UP || exit 1
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

> O `fiapx-contracts` ainda não é dependência do `auth-service`, por isso o build
> da imagem não precisa instalar o jar de contratos. Nos Dockerfiles do `video-api` e
> do worker (Tasks 15 e 20) o `fiapx-contracts` é instalado (`mvn install`) no
> repositório Maven local do próprio estágio de build.

- [ ] **Step 2: Escrever o `.dockerignore`**

```
.git
target
*.md
```

- [ ] **Step 3: Construir a imagem e verificar**

```bash
docker build -t fiapx/auth-service:local .
docker images fiapx/auth-service:local
```
Expected: imagem criada, tamanho abaixo de ~250 MB.

- [ ] **Step 4: Escrever o `README.md` do serviço**

```markdown
# fiapx-auth-service

Cadastro e autenticação do FIAP X. Emite JWT RS256 e publica a chave pública
em `/.well-known/jwks.json`.

| Método | Rota | Descrição |
|---|---|---|
| POST | `/api/v1/auth/register` | Cria usuário. `201`, `409` se o e-mail existe |
| POST | `/api/v1/auth/login` | Retorna `accessToken`. `401` em credenciais inválidas |
| GET | `/.well-known/jwks.json` | Chave pública para validação do token |

## Rodar os testes

    ./mvnw verify

Requer Docker: os testes de integração usam Testcontainers (PostgreSQL 16).

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `DB_URL` | `jdbc:postgresql://localhost:5432/auth_db` | JDBC do PostgreSQL |
| `DB_USER` / `DB_PASSWORD` | `fiapx` / `fiapx` | Credenciais |
| `JWT_PRIVATE_KEY_PEM` | vazio | PEM PKCS#8. Vazio gera chave efêmera (só para desenvolvimento) |
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "build: imagem multi-stage do auth-service

JRE alpine, usuario nao-root e healthcheck no probe de readiness."
```

---

## Task 8: `video-api` — esqueleto e domínio do vídeo

O coração do sistema: o value object que valida o arquivo e a máquina de estados que garante idempotência.

**Files:**
- Create: `services/fiapx-video-api/pom.xml`
- Create: `src/main/java/br/com/fiapx/video/VideoApiApplication.java`
- Create: `src/main/java/br/com/fiapx/video/domain/{VideoFile,VideoStatus,Video}.java`
- Create: `src/main/java/br/com/fiapx/video/domain/exception/{DomainException,InvalidVideoFileException,VideoNotFoundException,VideoNotReadyException}.java`
- Test: `src/test/java/br/com/fiapx/video/domain/{VideoFileTest,VideoStatusTest,VideoTest}.java`

**Interfaces:**
- Consumes: `ErrorCode` de `br.com.fiapx.contracts` (Task 2).
- Produces:
  - `VideoFile(String filename, long sizeBytes)` — record; `extension()`; constantes `ALLOWED_EXTENSIONS` e `MAX_SIZE_BYTES`
  - `VideoStatus` — enum com `canTransitionTo(VideoStatus)`
  - `Video.submit(UUID userId, String userEmail, VideoFile file, String s3RawKey)` → `Video`
  - `Video.rehydrate(...)` → `Video`
  - `boolean markProcessing()`, `boolean markCompleted(String s3ZipKey, int frameCount)`, `boolean markFailed(ErrorCode code, String message)` — retornam `false` quando a transição não é permitida
  - Acessores: `id()`, `userId()`, `userEmail()`, `originalFilename()`, `sizeBytes()`, `s3RawKey()`, `s3ZipKey()`, `status()`, `frameCount()`, `errorCode()`, `errorMessage()`, `attempts()`, `createdAt()`, `startedAt()`, `finishedAt()`

- [ ] **Step 1: Criar o repositório, o Maven wrapper e o `pom.xml`**

```bash
cd services && mkdir -p fiapx-video-api && cd fiapx-video-api && git init
cp -r ../fiapx-contracts/mvnw ../fiapx-contracts/mvnw.cmd ../fiapx-contracts/.mvn \
      ../fiapx-contracts/.gitattributes ../fiapx-contracts/.gitignore .
```

`pom.xml`:
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
    <artifactId>fiapx-video-api</artifactId>
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

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-validation</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-security</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-data-jpa</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-actuator</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springdoc</groupId>
            <artifactId>springdoc-openapi-starter-webmvc-ui</artifactId>
            <version>2.6.0</version>
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
            <artifactId>spring-cloud-aws-starter-s3</artifactId>
        </dependency>
        <dependency>
            <groupId>io.awspring.cloud</groupId>
            <artifactId>spring-cloud-aws-starter-sqs</artifactId>
        </dependency>
        <dependency>
            <groupId>software.amazon.awssdk</groupId>
            <artifactId>s3</artifactId>
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
            <groupId>org.springframework.security</groupId>
            <artifactId>spring-security-test</artifactId>
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
                                        <include>br.com.fiapx.video.domain*</include>
                                        <include>br.com.fiapx.video.application*</include>
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

- [ ] **Step 2: Escrever os testes de domínio (falham)**

`src/test/java/br/com/fiapx/video/domain/VideoFileTest.java`:
```java
package br.com.fiapx.video.domain;

import br.com.fiapx.video.domain.exception.InvalidVideoFileException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class VideoFileTest {

    @ParameterizedTest
    @ValueSource(strings = {"a.mp4", "a.AVI", "meu video.mov", "x.mkv", "x.wmv", "x.flv", "x.webm"})
    void aceitaTodasAsExtensoesDoProjetoBase(String nome) {
        assertThat(new VideoFile(nome, 1024L).filename()).isEqualTo(nome);
    }

    @Test
    void normalizaAExtensaoParaMinusculas() {
        assertThat(new VideoFile("CLIPE.MP4", 1024L).extension()).isEqualTo("mp4");
    }

    @ParameterizedTest
    @ValueSource(strings = {"documento.pdf", "imagem.png", "semextensao", "arquivo.mp4.exe"})
    void rejeitaFormatoNaoSuportado(String nome) {
        assertThatThrownBy(() -> new VideoFile(nome, 1024L))
                .isInstanceOf(InvalidVideoFileException.class);
    }

    @Test
    void rejeitaArquivoVazio() {
        assertThatThrownBy(() -> new VideoFile("a.mp4", 0L))
                .isInstanceOf(InvalidVideoFileException.class);
    }

    @Test
    void rejeitaArquivoAcimaDoLimiteDe200Mb() {
        assertThatThrownBy(() -> new VideoFile("a.mp4", VideoFile.MAX_SIZE_BYTES + 1))
                .isInstanceOf(InvalidVideoFileException.class)
                .hasMessageContaining("200");
    }

    @Test
    void aceitaExatamenteOLimite() {
        assertThat(new VideoFile("a.mp4", VideoFile.MAX_SIZE_BYTES).sizeBytes())
                .isEqualTo(209715200L);
    }
}
```

`src/test/java/br/com/fiapx/video/domain/VideoStatusTest.java`:
```java
package br.com.fiapx.video.domain;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class VideoStatusTest {

    @Test
    void permiteApenasAsTransicoesDaEspecificacao() {
        assertThat(VideoStatus.PENDING.canTransitionTo(VideoStatus.PROCESSING)).isTrue();
        assertThat(VideoStatus.PENDING.canTransitionTo(VideoStatus.FAILED)).isTrue();
        assertThat(VideoStatus.PROCESSING.canTransitionTo(VideoStatus.COMPLETED)).isTrue();
        assertThat(VideoStatus.PROCESSING.canTransitionTo(VideoStatus.FAILED)).isTrue();
    }

    @Test
    void bloqueiaRetrocessoEEstadosTerminais() {
        assertThat(VideoStatus.PENDING.canTransitionTo(VideoStatus.COMPLETED)).isFalse();
        assertThat(VideoStatus.PROCESSING.canTransitionTo(VideoStatus.PENDING)).isFalse();
        assertThat(VideoStatus.COMPLETED.canTransitionTo(VideoStatus.PROCESSING)).isFalse();
        assertThat(VideoStatus.COMPLETED.canTransitionTo(VideoStatus.FAILED)).isFalse();
        assertThat(VideoStatus.FAILED.canTransitionTo(VideoStatus.COMPLETED)).isFalse();
    }

    @Test
    void nenhumEstadoTransicionaParaSiMesmo() {
        for (VideoStatus status : VideoStatus.values()) {
            assertThat(status.canTransitionTo(status)).isFalse();
        }
    }
}
```

`src/test/java/br/com/fiapx/video/domain/VideoTest.java`:
```java
package br.com.fiapx.video.domain;

import br.com.fiapx.contracts.ErrorCode;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class VideoTest {

    private Video novoVideo() {
        return Video.submit(UUID.randomUUID(), "aluno@fiap.com.br",
                new VideoFile("clipe.mp4", 1024L), "raw/u/v.mp4");
    }

    @Test
    void nasceEmPendingComIdEDataGerados() {
        var video = novoVideo();

        assertThat(video.id()).isNotNull();
        assertThat(video.status()).isEqualTo(VideoStatus.PENDING);
        assertThat(video.attempts()).isZero();
        assertThat(video.createdAt()).isNotNull();
        assertThat(video.startedAt()).isNull();
        assertThat(video.finishedAt()).isNull();
    }

    @Test
    void markProcessingRegistraInicioEIncrementaTentativa() {
        var video = novoVideo();

        assertThat(video.markProcessing()).isTrue();
        assertThat(video.status()).isEqualTo(VideoStatus.PROCESSING);
        assertThat(video.startedAt()).isNotNull();
        assertThat(video.attempts()).isEqualTo(1);
    }

    @Test
    void markCompletedGuardaChaveDoZipEContagemDeFrames() {
        var video = novoVideo();
        video.markProcessing();

        assertThat(video.markCompleted("processed/u/v.zip", 42)).isTrue();
        assertThat(video.status()).isEqualTo(VideoStatus.COMPLETED);
        assertThat(video.s3ZipKey()).isEqualTo("processed/u/v.zip");
        assertThat(video.frameCount()).isEqualTo(42);
        assertThat(video.finishedAt()).isNotNull();
    }

    @Test
    void markFailedGuardaCodigoEMensagem() {
        var video = novoVideo();
        video.markProcessing();

        assertThat(video.markFailed(ErrorCode.FFMPEG_FAILURE, "codec invalido")).isTrue();
        assertThat(video.status()).isEqualTo(VideoStatus.FAILED);
        assertThat(video.errorCode()).isEqualTo(ErrorCode.FFMPEG_FAILURE);
        assertThat(video.errorMessage()).isEqualTo("codec invalido");
    }

    @Test
    void entregaDuplicadaDeCompletedNaoAlteraOEstado() {
        var video = novoVideo();
        video.markProcessing();
        video.markCompleted("processed/u/v.zip", 42);

        assertThat(video.markCompleted("processed/u/OUTRO.zip", 99)).isFalse();
        assertThat(video.s3ZipKey()).isEqualTo("processed/u/v.zip");
        assertThat(video.frameCount()).isEqualTo(42);
    }

    @Test
    void naoPodeFalharDepoisDeConcluido() {
        var video = novoVideo();
        video.markProcessing();
        video.markCompleted("processed/u/v.zip", 1);

        assertThat(video.markFailed(ErrorCode.UNKNOWN, "tarde demais")).isFalse();
        assertThat(video.status()).isEqualTo(VideoStatus.COMPLETED);
        assertThat(video.errorCode()).isNull();
    }

    @Test
    void podeFalharDiretoDePendingQuandoOWorkerNemComecou() {
        var video = novoVideo();

        assertThat(video.markFailed(ErrorCode.STORAGE_FAILURE, "objeto sumiu")).isTrue();
        assertThat(video.status()).isEqualTo(VideoStatus.FAILED);
    }

    @Test
    void reprocessamentoAposFalhaNaoEPermitido() {
        var video = novoVideo();
        video.markProcessing();
        video.markFailed(ErrorCode.TIMEOUT, "estourou");

        assertThat(video.markProcessing()).isFalse();
        assertThat(video.attempts()).isEqualTo(1);
    }
}
```

- [ ] **Step 3: Rodar e confirmar que falham**

Run: `./mvnw test`
Expected: FAIL na compilação — nenhuma classe de domínio existe.

- [ ] **Step 4: Implementar as exceções**

`domain/exception/DomainException.java` e as três filhas, cada uma em seu arquivo:
```java
package br.com.fiapx.video.domain.exception;

public abstract class DomainException extends RuntimeException {
    protected DomainException(String message) { super(message); }
}
```
```java
public class InvalidVideoFileException extends DomainException {
    public InvalidVideoFileException(String message) { super(message); }
}
public class VideoNotFoundException extends DomainException {
    public VideoNotFoundException(String message) { super(message); }
}
public class VideoNotReadyException extends DomainException {
    public VideoNotReadyException(String message) { super(message); }
}
```

- [ ] **Step 5: Implementar `VideoFile` e `VideoStatus`**

`domain/VideoFile.java`:
```java
package br.com.fiapx.video.domain;

import br.com.fiapx.video.domain.exception.InvalidVideoFileException;

import java.util.Locale;
import java.util.Set;

public record VideoFile(String filename, long sizeBytes) {

    public static final Set<String> ALLOWED_EXTENSIONS =
            Set.of("mp4", "avi", "mov", "mkv", "wmv", "flv", "webm");

    public static final long MAX_SIZE_BYTES = 200L * 1024 * 1024;

    public VideoFile {
        if (filename == null || filename.isBlank()) {
            throw new InvalidVideoFileException("Nome de arquivo vazio");
        }
        if (sizeBytes <= 0) {
            throw new InvalidVideoFileException("Arquivo vazio");
        }
        if (sizeBytes > MAX_SIZE_BYTES) {
            throw new InvalidVideoFileException("Arquivo excede o limite de 200 MB");
        }
        if (!ALLOWED_EXTENSIONS.contains(extensionOf(filename))) {
            throw new InvalidVideoFileException(
                    "Formato nao suportado. Use: " + String.join(", ", ALLOWED_EXTENSIONS));
        }
    }

    public String extension() {
        return extensionOf(filename);
    }

    private static String extensionOf(String name) {
        int dot = name.lastIndexOf('.');
        return dot < 0 ? "" : name.substring(dot + 1).toLowerCase(Locale.ROOT);
    }
}
```

`domain/VideoStatus.java`:
```java
package br.com.fiapx.video.domain;

import java.util.EnumSet;
import java.util.Map;
import java.util.Set;

public enum VideoStatus {

    PENDING,
    PROCESSING,
    COMPLETED,
    FAILED;

    private static final Map<VideoStatus, Set<VideoStatus>> ALLOWED = Map.of(
            PENDING, EnumSet.of(PROCESSING, FAILED),
            PROCESSING, EnumSet.of(COMPLETED, FAILED),
            COMPLETED, EnumSet.noneOf(VideoStatus.class),
            FAILED, EnumSet.noneOf(VideoStatus.class));

    public boolean canTransitionTo(VideoStatus target) {
        return ALLOWED.get(this).contains(target);
    }

    public boolean isTerminal() {
        return this == COMPLETED || this == FAILED;
    }
}
```

- [ ] **Step 6: Implementar o agregado `Video`**

`domain/Video.java`:
```java
package br.com.fiapx.video.domain;

import br.com.fiapx.contracts.ErrorCode;

import java.time.Instant;
import java.util.Objects;
import java.util.UUID;

public final class Video {

    private final UUID id;
    private final UUID userId;
    private final String userEmail;
    private final String originalFilename;
    private final long sizeBytes;
    private final String s3RawKey;
    private final Instant createdAt;

    private VideoStatus status;
    private String s3ZipKey;
    private Integer frameCount;
    private ErrorCode errorCode;
    private String errorMessage;
    private int attempts;
    private Instant startedAt;
    private Instant finishedAt;

    private Video(UUID id, UUID userId, String userEmail, String originalFilename, long sizeBytes,
                  String s3RawKey, VideoStatus status, String s3ZipKey, Integer frameCount,
                  ErrorCode errorCode, String errorMessage, int attempts,
                  Instant createdAt, Instant startedAt, Instant finishedAt) {
        this.id = Objects.requireNonNull(id);
        this.userId = Objects.requireNonNull(userId);
        this.userEmail = Objects.requireNonNull(userEmail);
        this.originalFilename = Objects.requireNonNull(originalFilename);
        this.sizeBytes = sizeBytes;
        this.s3RawKey = Objects.requireNonNull(s3RawKey);
        this.status = Objects.requireNonNull(status);
        this.s3ZipKey = s3ZipKey;
        this.frameCount = frameCount;
        this.errorCode = errorCode;
        this.errorMessage = errorMessage;
        this.attempts = attempts;
        this.createdAt = Objects.requireNonNull(createdAt);
        this.startedAt = startedAt;
        this.finishedAt = finishedAt;
    }

    public static Video submit(UUID userId, String userEmail, VideoFile file, String s3RawKey) {
        return new Video(UUID.randomUUID(), userId, userEmail, file.filename(), file.sizeBytes(),
                s3RawKey, VideoStatus.PENDING, null, null, null, null, 0,
                Instant.now(), null, null);
    }

    public static Video rehydrate(UUID id, UUID userId, String userEmail, String originalFilename,
                                  long sizeBytes, String s3RawKey, VideoStatus status, String s3ZipKey,
                                  Integer frameCount, ErrorCode errorCode, String errorMessage,
                                  int attempts, Instant createdAt, Instant startedAt, Instant finishedAt) {
        return new Video(id, userId, userEmail, originalFilename, sizeBytes, s3RawKey, status,
                s3ZipKey, frameCount, errorCode, errorMessage, attempts, createdAt, startedAt, finishedAt);
    }

    public boolean markProcessing() {
        if (!status.canTransitionTo(VideoStatus.PROCESSING)) {
            return false;
        }
        status = VideoStatus.PROCESSING;
        startedAt = Instant.now();
        attempts++;
        return true;
    }

    public boolean markCompleted(String s3ZipKey, int frameCount) {
        if (!status.canTransitionTo(VideoStatus.COMPLETED)) {
            return false;
        }
        status = VideoStatus.COMPLETED;
        this.s3ZipKey = Objects.requireNonNull(s3ZipKey);
        this.frameCount = frameCount;
        finishedAt = Instant.now();
        return true;
    }

    public boolean markFailed(ErrorCode errorCode, String errorMessage) {
        if (!status.canTransitionTo(VideoStatus.FAILED)) {
            return false;
        }
        status = VideoStatus.FAILED;
        this.errorCode = Objects.requireNonNull(errorCode);
        this.errorMessage = errorMessage;
        finishedAt = Instant.now();
        return true;
    }

    public boolean belongsTo(UUID candidateUserId) {
        return userId.equals(candidateUserId);
    }

    public UUID id() { return id; }
    public UUID userId() { return userId; }
    public String userEmail() { return userEmail; }
    public String originalFilename() { return originalFilename; }
    public long sizeBytes() { return sizeBytes; }
    public String s3RawKey() { return s3RawKey; }
    public String s3ZipKey() { return s3ZipKey; }
    public VideoStatus status() { return status; }
    public Integer frameCount() { return frameCount; }
    public ErrorCode errorCode() { return errorCode; }
    public String errorMessage() { return errorMessage; }
    public int attempts() { return attempts; }
    public Instant createdAt() { return createdAt; }
    public Instant startedAt() { return startedAt; }
    public Instant finishedAt() { return finishedAt; }
}
```

`VideoApiApplication.java`:
```java
package br.com.fiapx.video;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class VideoApiApplication {
    public static void main(String[] args) {
        SpringApplication.run(VideoApiApplication.class, args);
    }
}
```

- [ ] **Step 7: Rodar os testes e confirmar que passam**

Run: `./mvnw test`
Expected: PASS — 17 testes de domínio verdes.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: dominio do video com maquina de estados idempotente

VideoFile valida extensao e limite de 200 MB na construcao. Os metodos
mark* retornam false em transicao proibida em vez de lancar excecao, o que
torna a entrega duplicada do SQS inofensiva."
```

---

## Task 9: `video-api` — persistência com histórico de status

**Files:**
- Create: `src/main/resources/db/migration/V1__create_videos.sql`
- Create: `src/main/resources/application.yml`
- Create: `src/main/java/br/com/fiapx/video/application/port/out/VideoRepository.java`
- Create: `src/main/java/br/com/fiapx/video/infrastructure/persistence/{VideoEntity,VideoStatusHistoryEntity,SpringDataVideoRepository,SpringDataVideoStatusHistoryRepository,JpaVideoRepository}.java`
- Test: `src/test/java/br/com/fiapx/video/support/PostgresTestContainer.java`
- Test: `src/test/java/br/com/fiapx/video/infrastructure/persistence/JpaVideoRepositoryIT.java`

**Interfaces:**
- Consumes: `Video`, `VideoStatus`, `VideoFile` (Task 8).
- Produces:
  - `VideoRepository` (port): `void save(Video video)`, `Optional<Video> findById(UUID id)`, `Optional<Video> findByIdAndUserId(UUID id, UUID userId)`, `List<Video> findByUserId(UUID userId, VideoStatus filtroOuNull, int page, int size)`, `long countByUserId(UUID userId)`

- [ ] **Step 1: Escrever a migration `V1__create_videos.sql`**

```sql
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
```

- [ ] **Step 2: Escrever o `application.yml`**

```yaml
server:
  port: 8082

spring:
  application:
    name: fiapx-video-api
  datasource:
    url: ${DB_URL:jdbc:postgresql://localhost:5432/video_db}
    username: ${DB_USER:fiapx}
    password: ${DB_PASSWORD:fiapx}
  jpa:
    hibernate:
      ddl-auto: validate
    open-in-view: false
  flyway:
    enabled: true
  servlet:
    multipart:
      max-file-size: 200MB
      max-request-size: 210MB
  security:
    oauth2:
      resourceserver:
        jwt:
          jwk-set-uri: ${JWKS_URI:http://localhost:8081/.well-known/jwks.json}

fiapx:
  s3:
    bucket: ${S3_BUCKET:fiapx-videos}
    presign-ttl-minutes: 15
    # Host usado SÓ na URL assinada devolvida ao navegador. No Compose, o serviço
    # fala com "localstack:4566", mas o navegador do usuário só alcança
    # "localhost:4566". Vazio = mesmo endpoint do SDK (AWS real).
    public-endpoint: ${S3_PUBLIC_ENDPOINT:}
  sqs:
    processing-queue: ${SQS_PROCESSING_QUEUE:video-processing-queue}
    status-queue: ${SQS_STATUS_QUEUE:video-status-queue}

spring.cloud.aws:
  region:
    static: ${AWS_REGION:us-east-1}
  endpoint: ${AWS_ENDPOINT:}
  s3:
    # true no LocalStack: sem isso o SDK monta "fiapx-videos.localstack:4566", host
    # que não resolve. Na AWS real fica false (virtual-hosted style).
    path-style-access-enabled: ${S3_PATH_STYLE:false}
  credentials:
    access-key: ${AWS_ACCESS_KEY_ID:test}
    secret-key: ${AWS_SECRET_ACCESS_KEY:test}

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

- [ ] **Step 3: Escrever o teste de integração (falha)**

`src/test/java/br/com/fiapx/video/support/PostgresTestContainer.java` — idêntico ao do `auth-service`, trocando o banco para `video_db` e o pacote para `br.com.fiapx.video.support`.

`src/test/java/br/com/fiapx/video/infrastructure/persistence/JpaVideoRepositoryIT.java`:
```java
package br.com.fiapx.video.infrastructure.persistence;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoFile;
import br.com.fiapx.video.domain.VideoStatus;
import br.com.fiapx.video.support.PostgresTestContainer;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.TestPropertySource;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@Import(PostgresTestContainer.class)
@TestPropertySource(properties = "spring.security.oauth2.resourceserver.jwt.jwk-set-uri=http://localhost:0/jwks")
class JpaVideoRepositoryIT {

    @Autowired
    VideoRepository repository;

    private Video novoVideo(UUID userId) {
        return Video.submit(userId, "aluno@fiap.com.br",
                new VideoFile("clipe.mp4", 2048L), "raw/" + userId + "/v.mp4");
    }

    @Test
    void salvaERecuperaPreservandoOEstado() {
        UUID userId = UUID.randomUUID();
        var video = novoVideo(userId);
        video.markProcessing();
        video.markCompleted("processed/u/v.zip", 42);
        repository.save(video);

        var encontrado = repository.findById(video.id()).orElseThrow();

        assertThat(encontrado.status()).isEqualTo(VideoStatus.COMPLETED);
        assertThat(encontrado.frameCount()).isEqualTo(42);
        assertThat(encontrado.s3ZipKey()).isEqualTo("processed/u/v.zip");
        assertThat(encontrado.attempts()).isEqualTo(1);
        assertThat(encontrado.finishedAt()).isNotNull();
    }

    @Test
    void persisteCodigoDeErro() {
        var video = novoVideo(UUID.randomUUID());
        video.markFailed(ErrorCode.NO_FRAMES_EXTRACTED, "video sem frames");
        repository.save(video);

        var encontrado = repository.findById(video.id()).orElseThrow();

        assertThat(encontrado.errorCode()).isEqualTo(ErrorCode.NO_FRAMES_EXTRACTED);
        assertThat(encontrado.errorMessage()).isEqualTo("video sem frames");
    }

    @Test
    void findByIdAndUserIdIsolaUsuarios() {
        UUID dono = UUID.randomUUID();
        var video = novoVideo(dono);
        repository.save(video);

        assertThat(repository.findByIdAndUserId(video.id(), dono)).isPresent();
        assertThat(repository.findByIdAndUserId(video.id(), UUID.randomUUID())).isEmpty();
    }

    @Test
    void listaApenasOsVideosDoUsuarioMaisRecentesPrimeiro() {
        UUID dono = UUID.randomUUID();
        var primeiro = novoVideo(dono);
        repository.save(primeiro);
        var segundo = novoVideo(dono);
        repository.save(segundo);
        repository.save(novoVideo(UUID.randomUUID()));

        var pagina = repository.findByUserId(dono, null, 0, 10);

        assertThat(pagina).hasSize(2);
        assertThat(pagina.get(0).id()).isEqualTo(segundo.id());
        assertThat(repository.countByUserId(dono)).isEqualTo(2);
    }

    @Test
    void filtraPorStatus() {
        UUID dono = UUID.randomUUID();
        var pendente = novoVideo(dono);
        repository.save(pendente);

        var concluido = novoVideo(dono);
        concluido.markProcessing();
        concluido.markCompleted("processed/u/x.zip", 3);
        repository.save(concluido);

        assertThat(repository.findByUserId(dono, VideoStatus.COMPLETED, 0, 10))
                .singleElement()
                .satisfies(v -> assertThat(v.id()).isEqualTo(concluido.id()));
    }

    @Test
    void gravaOHistoricoDeTransicoes() {
        var video = novoVideo(UUID.randomUUID());
        repository.save(video);
        video.markProcessing();
        repository.save(video);
        video.markCompleted("processed/u/v.zip", 7);
        repository.save(video);

        assertThat(repository.findById(video.id())).isPresent();
    }
}
```

- [ ] **Step 4: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*JpaVideoRepositoryIT'`
Expected: FAIL — `VideoRepository` não existe.

- [ ] **Step 5: Implementar o port**

`application/port/out/VideoRepository.java`:
```java
package br.com.fiapx.video.application.port.out;

import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoStatus;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface VideoRepository {

    void save(Video video);

    Optional<Video> findById(UUID id);

    Optional<Video> findByIdAndUserId(UUID id, UUID userId);

    /** @param status filtro opcional; {@code null} retorna todos os estados. */
    List<Video> findByUserId(UUID userId, VideoStatus status, int page, int size);

    long countByUserId(UUID userId);
}
```

- [ ] **Step 6: Implementar as entidades e o adapter**

`infrastructure/persistence/VideoEntity.java`:
```java
package br.com.fiapx.video.infrastructure.persistence;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoStatus;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "videos")
class VideoEntity {

    @Id
    private UUID id;

    @Column(name = "user_id", nullable = false)
    private UUID userId;

    @Column(name = "user_email", nullable = false)
    private String userEmail;

    @Column(name = "original_filename", nullable = false)
    private String originalFilename;

    @Column(name = "size_bytes", nullable = false)
    private long sizeBytes;

    @Column(name = "s3_raw_key", nullable = false)
    private String s3RawKey;

    @Column(name = "s3_zip_key")
    private String s3ZipKey;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private VideoStatus status;

    @Column(name = "frame_count")
    private Integer frameCount;

    @Enumerated(EnumType.STRING)
    @Column(name = "error_code", length = 40)
    private ErrorCode errorCode;

    @Column(name = "error_message")
    private String errorMessage;

    @Column(nullable = false)
    private int attempts;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt;

    @Column(name = "started_at")
    private Instant startedAt;

    @Column(name = "finished_at")
    private Instant finishedAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    protected VideoEntity() {
    }

    static VideoEntity from(Video video) {
        VideoEntity e = new VideoEntity();
        e.id = video.id();
        e.userId = video.userId();
        e.userEmail = video.userEmail();
        e.originalFilename = video.originalFilename();
        e.sizeBytes = video.sizeBytes();
        e.s3RawKey = video.s3RawKey();
        e.s3ZipKey = video.s3ZipKey();
        e.status = video.status();
        e.frameCount = video.frameCount();
        e.errorCode = video.errorCode();
        e.errorMessage = video.errorMessage();
        e.attempts = video.attempts();
        e.createdAt = video.createdAt();
        e.startedAt = video.startedAt();
        e.finishedAt = video.finishedAt();
        e.updatedAt = Instant.now();
        return e;
    }

    Video toDomain() {
        return Video.rehydrate(id, userId, userEmail, originalFilename, sizeBytes, s3RawKey,
                status, s3ZipKey, frameCount, errorCode, errorMessage, attempts,
                createdAt, startedAt, finishedAt);
    }

    VideoStatus status() {
        return status;
    }
}
```

`infrastructure/persistence/VideoStatusHistoryEntity.java`:
```java
package br.com.fiapx.video.infrastructure.persistence;

import br.com.fiapx.video.domain.VideoStatus;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "video_status_history")
class VideoStatusHistoryEntity {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "video_id", nullable = false)
    private UUID videoId;

    @Enumerated(EnumType.STRING)
    @Column(name = "from_status", length = 20)
    private VideoStatus fromStatus;

    @Enumerated(EnumType.STRING)
    @Column(name = "to_status", nullable = false, length = 20)
    private VideoStatus toStatus;

    @Column
    private String reason;

    @Column(name = "changed_at", nullable = false)
    private Instant changedAt;

    protected VideoStatusHistoryEntity() {
    }

    static VideoStatusHistoryEntity of(UUID videoId, VideoStatus from, VideoStatus to, String reason) {
        VideoStatusHistoryEntity e = new VideoStatusHistoryEntity();
        e.videoId = videoId;
        e.fromStatus = from;
        e.toStatus = to;
        e.reason = reason;
        e.changedAt = Instant.now();
        return e;
    }
}
```

`infrastructure/persistence/SpringDataVideoRepository.java`:
```java
package br.com.fiapx.video.infrastructure.persistence;

import br.com.fiapx.video.domain.VideoStatus;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

interface SpringDataVideoRepository extends JpaRepository<VideoEntity, UUID> {

    Optional<VideoEntity> findByIdAndUserId(UUID id, UUID userId);

    @Query("""
            select v from VideoEntity v
            where v.userId = :userId
              and (:status is null or v.status = :status)
            order by v.createdAt desc
            """)
    List<VideoEntity> search(UUID userId, VideoStatus status, Pageable pageable);

    long countByUserId(UUID userId);
}
```

`infrastructure/persistence/SpringDataVideoStatusHistoryRepository.java`:
```java
package br.com.fiapx.video.infrastructure.persistence;

import org.springframework.data.jpa.repository.JpaRepository;

interface SpringDataVideoStatusHistoryRepository extends JpaRepository<VideoStatusHistoryEntity, Long> {
}
```

`infrastructure/persistence/JpaVideoRepository.java`:
```java
package br.com.fiapx.video.infrastructure.persistence;

import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoStatus;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
class JpaVideoRepository implements VideoRepository {

    private final SpringDataVideoRepository videos;
    private final SpringDataVideoStatusHistoryRepository history;

    JpaVideoRepository(SpringDataVideoRepository videos, SpringDataVideoStatusHistoryRepository history) {
        this.videos = videos;
        this.history = history;
    }

    @Override
    @Transactional
    public void save(Video video) {
        VideoStatus anterior = videos.findById(video.id())
                .map(VideoEntity::status)
                .orElse(null);

        videos.save(VideoEntity.from(video));

        if (anterior != video.status()) {
            history.save(VideoStatusHistoryEntity.of(
                    video.id(), anterior, video.status(), video.errorMessage()));
        }
    }

    @Override
    public Optional<Video> findById(UUID id) {
        return videos.findById(id).map(VideoEntity::toDomain);
    }

    @Override
    public Optional<Video> findByIdAndUserId(UUID id, UUID userId) {
        return videos.findByIdAndUserId(id, userId).map(VideoEntity::toDomain);
    }

    @Override
    public List<Video> findByUserId(UUID userId, VideoStatus status, int page, int size) {
        return videos.search(userId, status, PageRequest.of(page, size)).stream()
                .map(VideoEntity::toDomain)
                .toList();
    }

    @Override
    public long countByUserId(UUID userId) {
        return videos.countByUserId(userId);
    }
}
```

- [ ] **Step 7: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*JpaVideoRepositoryIT'`
Expected: PASS — 6 testes verdes.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: persistencia de videos com historico de transicoes

O adapter grava uma linha em video_status_history sempre que o estado muda,
dando rastro de auditoria sem poluir o agregado de dominio."
```

---

## Task 10: `video-api` — armazenamento no S3 e link assinado

**Files:**
- Create: `src/main/java/br/com/fiapx/video/application/port/out/VideoStorage.java`
- Create: `src/main/java/br/com/fiapx/video/infrastructure/config/AwsConfig.java`
- Create: `src/main/java/br/com/fiapx/video/infrastructure/storage/S3VideoStorage.java`
- Create: `src/main/java/br/com/fiapx/video/application/exception/StorageException.java`
- Test: `src/test/java/br/com/fiapx/video/support/LocalStackTestContainer.java`
- Test: `src/test/java/br/com/fiapx/video/infrastructure/storage/S3VideoStorageIT.java`

**Interfaces:**
- Consumes: nada de tarefas anteriores.
- Produces:
  - `VideoStorage` (port): `String storeRaw(UUID userId, UUID videoId, String extension, InputStream content, long sizeBytes)` → devolve a chave S3; `URL presignedDownloadUrl(String key, Duration ttl)`
  - `DownloadLink(String url, Instant expiresAt)` — usado na Task 14

- [ ] **Step 1: Escrever o teste de integração (falha)**

`src/test/java/br/com/fiapx/video/support/LocalStackTestContainer.java`:
```java
package br.com.fiapx.video.support;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.testcontainers.containers.localstack.LocalStackContainer;
import org.testcontainers.utility.DockerImageName;

import static org.testcontainers.containers.localstack.LocalStackContainer.Service.S3;
import static org.testcontainers.containers.localstack.LocalStackContainer.Service.SNS;
import static org.testcontainers.containers.localstack.LocalStackContainer.Service.SQS;

/**
 * Publica o endpoint do LocalStack como propriedades spring.cloud.aws.*, e não via
 * {@code @ServiceConnection}: o Boot não tem ConnectionDetails para o LocalStack, e o
 * presigner do AwsConfig lê essas mesmas propriedades.
 */
@TestConfiguration(proxyBeanMethods = false)
public class LocalStackTestContainer {

    @Bean
    LocalStackContainer localStack(DynamicPropertyRegistry registry) {
        LocalStackContainer container = new LocalStackContainer(DockerImageName.parse("localstack/localstack:3.8"))
                .withServices(S3, SQS, SNS);
        registry.add("spring.cloud.aws.endpoint", () -> container.getEndpoint().toString());
        registry.add("spring.cloud.aws.region.static", container::getRegion);
        registry.add("spring.cloud.aws.credentials.access-key", container::getAccessKey);
        registry.add("spring.cloud.aws.credentials.secret-key", container::getSecretKey);
        registry.add("spring.cloud.aws.s3.path-style-access-enabled", () -> "true");
        return container;
    }
}
```

`src/test/java/br/com/fiapx/video/infrastructure/storage/S3VideoStorageIT.java`:
```java
package br.com.fiapx.video.infrastructure.storage;

import br.com.fiapx.video.application.port.out.VideoStorage;
import br.com.fiapx.video.support.LocalStackTestContainer;
import br.com.fiapx.video.support.PostgresTestContainer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.TestPropertySource;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.S3Exception;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@Import({LocalStackTestContainer.class, PostgresTestContainer.class})
@TestPropertySource(properties = "spring.security.oauth2.resourceserver.jwt.jwk-set-uri=http://localhost:0/jwks")
class S3VideoStorageIT {

    @Autowired
    VideoStorage storage;

    @Autowired
    S3Client s3;

    @Value("${fiapx.s3.bucket}")
    String bucket;

    @BeforeEach
    void criarBucket() {
        try {
            s3.headBucket(b -> b.bucket(bucket));
        } catch (S3Exception ex) { // NoSuchBucketException é subtipo de S3Exception
            s3.createBucket(b -> b.bucket(bucket));
        }
    }

    @Test
    void gravaOVideoNaChaveRawDoUsuario() {
        UUID userId = UUID.randomUUID();
        UUID videoId = UUID.randomUUID();
        byte[] conteudo = "conteudo-de-video".getBytes(StandardCharsets.UTF_8);

        String key = storage.storeRaw(userId, videoId, "mp4",
                new ByteArrayInputStream(conteudo), conteudo.length);

        assertThat(key).isEqualTo("raw/" + userId + "/" + videoId + ".mp4");
        assertThat(s3.getObjectAsBytes(b -> b.bucket(bucket).key(key)).asByteArray())
                .isEqualTo(conteudo);
    }

    @Test
    void geraLinkAssinadoQueBaixaOObjeto() throws Exception {
        String key = "processed/" + UUID.randomUUID() + "/arquivo.zip";
        s3.putObject(b -> b.bucket(bucket).key(key), RequestBody.fromString("zip-falso"));

        URL url = storage.presignedDownloadUrl(key, Duration.ofMinutes(15));

        assertThat(url.toString()).contains("X-Amz-Signature");
        HttpURLConnection conexao = (HttpURLConnection) url.openConnection();
        try (InputStream in = conexao.getInputStream()) {
            assertThat(new String(in.readAllBytes(), StandardCharsets.UTF_8)).isEqualTo("zip-falso");
        }
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*S3VideoStorageIT'`
Expected: FAIL — `VideoStorage` não existe.

- [ ] **Step 3: Implementar o port**

`application/port/out/VideoStorage.java`:
```java
package br.com.fiapx.video.application.port.out;

import java.io.InputStream;
import java.net.URL;
import java.time.Duration;
import java.util.UUID;

public interface VideoStorage {

    /** @return a chave S3 onde o vídeo foi gravado. */
    String storeRaw(UUID userId, UUID videoId, String extension, InputStream content, long sizeBytes);

    URL presignedDownloadUrl(String key, Duration ttl);
}
```

- [ ] **Step 4: Implementar a configuração AWS e o adapter**

`infrastructure/config/AwsConfig.java`:
```java
package br.com.fiapx.video.infrastructure.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

import java.net.URI;

@Configuration
public class AwsConfig {

    /**
     * O S3Client vem do spring-cloud-aws. O presigner precisa de um bean próprio,
     * e no LocalStack exige path-style para que a URL assinada seja acessível.
     * A URL vai para o navegador, então usa o endpoint público quando ele existe
     * (no Compose, "localhost:4566" em vez de "localstack:4566").
     */
    @Bean
    S3Presigner s3Presigner(@Value("${spring.cloud.aws.region.static}") String region,
                            @Value("${spring.cloud.aws.endpoint:}") String endpoint,
                            @Value("${fiapx.s3.public-endpoint:}") String publicEndpoint,
                            @Value("${spring.cloud.aws.credentials.access-key}") String accessKey,
                            @Value("${spring.cloud.aws.credentials.secret-key}") String secretKey) {
        S3Presigner.Builder builder = S3Presigner.builder()
                .region(Region.of(region))
                .credentialsProvider(StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(accessKey, secretKey)));

        String presignEndpoint = (publicEndpoint != null && !publicEndpoint.isBlank())
                ? publicEndpoint : endpoint;
        if (presignEndpoint != null && !presignEndpoint.isBlank()) {
            builder.endpointOverride(URI.create(presignEndpoint))
                   .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(true).build());
        }
        return builder.build();
    }
}
```

`infrastructure/storage/S3VideoStorage.java`:
```java
package br.com.fiapx.video.infrastructure.storage;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.video.application.port.out.VideoStorage;
import br.com.fiapx.video.application.exception.StorageException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.GetObjectPresignRequest;

import java.io.InputStream;
import java.net.URL;
import java.time.Duration;
import java.util.UUID;

@Component
class S3VideoStorage implements VideoStorage {

    private final S3Client s3;
    private final S3Presigner presigner;
    private final String bucket;

    S3VideoStorage(S3Client s3, S3Presigner presigner, @Value("${fiapx.s3.bucket}") String bucket) {
        this.s3 = s3;
        this.presigner = presigner;
        this.bucket = bucket;
    }

    @Override
    public String storeRaw(UUID userId, UUID videoId, String extension,
                           InputStream content, long sizeBytes) {
        String key = "raw/%s/%s.%s".formatted(userId, videoId, extension);
        try {
            PutObjectRequest request = PutObjectRequest.builder()
                    .bucket(bucket)
                    .key(key)
                    .contentLength(sizeBytes)
                    .build();
            s3.putObject(request, RequestBody.fromInputStream(content, sizeBytes));
            return key;
        } catch (RuntimeException ex) {
            throw new StorageException(ErrorCode.STORAGE_FAILURE, "Falha ao gravar o video no S3", ex);
        }
    }

    @Override
    public URL presignedDownloadUrl(String key, Duration ttl) {
        GetObjectPresignRequest request = GetObjectPresignRequest.builder()
                .signatureDuration(ttl)
                .getObjectRequest(GetObjectRequest.builder().bucket(bucket).key(key).build())
                .build();
        return presigner.presignGetObject(request).url();
    }
}
```

`application/exception/StorageException.java`:
```java
package br.com.fiapx.video.application.exception;

import br.com.fiapx.contracts.ErrorCode;

public class StorageException extends RuntimeException {

    private final ErrorCode errorCode;

    public StorageException(ErrorCode errorCode, String message, Throwable cause) {
        super(message, cause);
        this.errorCode = errorCode;
    }

    public ErrorCode errorCode() {
        return errorCode;
    }
}
```

`src/test/java/br/com/fiapx/video/infrastructure/storage/S3VideoStorageTest.java` — sem ele o
pacote `application.exception` fica com 0% de cobertura e derruba o gate do JaCoCo, que é
por pacote. Também é o único teste que garante a tradução de falha do SDK em `STORAGE_FAILURE`:
```java
package br.com.fiapx.video.infrastructure.storage;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.video.application.exception.StorageException;
import org.junit.jupiter.api.Test;
import software.amazon.awssdk.core.exception.SdkClientException;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

import java.io.ByteArrayInputStream;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class S3VideoStorageTest {

    @Test
    void falhaDoS3ViraStorageExceptionComCodigoDeErro() {
        S3Client s3 = mock(S3Client.class);
        when(s3.putObject(any(PutObjectRequest.class), any(RequestBody.class)))
                .thenThrow(SdkClientException.create("S3 fora do ar"));
        var storage = new S3VideoStorage(s3, mock(S3Presigner.class), "fiapx-videos");

        assertThatThrownBy(() -> storage.storeRaw(UUID.randomUUID(), UUID.randomUUID(), "mp4",
                new ByteArrayInputStream(new byte[]{1}), 1L))
                .isInstanceOfSatisfying(StorageException.class,
                        ex -> assertThat(ex.errorCode()).isEqualTo(ErrorCode.STORAGE_FAILURE))
                .hasCauseInstanceOf(SdkClientException.class);
    }
}
```

- [ ] **Step 5: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*S3VideoStorage*'`
Expected: PASS — o LocalStack sobe, o objeto é gravado na chave esperada e a URL assinada baixa o conteúdo.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: armazenamento no S3 com URL assinada de download

O presigner usa path-style quando ha endpoint customizado, o que faz a URL
assinada funcionar tanto no LocalStack quanto na AWS real."
```

---

## Task 11: `video-api` — submissão do vídeo e publicação na fila

**Files:**
- Create: `src/main/java/br/com/fiapx/video/application/port/out/VideoEventPublisher.java`
- Create: `src/main/java/br/com/fiapx/video/application/usecase/SubmitVideoUseCase.java`
- Create: `src/main/java/br/com/fiapx/video/infrastructure/messaging/SqsVideoEventPublisher.java`
- Test: `src/test/java/br/com/fiapx/video/application/usecase/SubmitVideoUseCaseTest.java`
- Test: `src/test/java/br/com/fiapx/video/infrastructure/messaging/SqsVideoEventPublisherIT.java`

**Interfaces:**
- Consumes: `Video`, `VideoFile` (Task 8); `VideoRepository` (Task 9); `VideoStorage` (Task 10); `EventEnvelope`, `VideoUploadedPayload`, `EventType` (Task 2).
- Produces:
  - `VideoEventPublisher` (port): `void publishUploaded(Video video)`
  - `SubmitVideoUseCase.execute(UUID userId, String userEmail, String filename, long sizeBytes, InputStream content)` → `Video` em `PENDING`

- [ ] **Step 1: Escrever o teste do use case (falha)**

```java
package br.com.fiapx.video.application.usecase;

import br.com.fiapx.video.application.port.out.VideoEventPublisher;
import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.application.port.out.VideoStorage;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoStatus;
import br.com.fiapx.video.domain.exception.InvalidVideoFileException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SubmitVideoUseCaseTest {

    private VideoRepository repository;
    private VideoStorage storage;
    private VideoEventPublisher publisher;
    private SubmitVideoUseCase useCase;

    private final UUID userId = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        repository = mock(VideoRepository.class);
        storage = mock(VideoStorage.class);
        publisher = mock(VideoEventPublisher.class);
        useCase = new SubmitVideoUseCase(repository, storage, publisher);
        when(storage.storeRaw(any(), any(), anyString(), any(), anyLong()))
                .thenReturn("raw/u/v.mp4");
    }

    private InputStream conteudo() {
        return new ByteArrayInputStream(new byte[]{1, 2, 3});
    }

    @Test
    void gravaNoStoragePersistePendingEPublicaNaFila() {
        var video = useCase.execute(userId, "aluno@fiap.com.br", "clipe.mp4", 2048L, conteudo());

        assertThat(video.status()).isEqualTo(VideoStatus.PENDING);
        assertThat(video.s3RawKey()).isEqualTo("raw/u/v.mp4");

        InOrder ordem = inOrder(storage, repository, publisher);
        ordem.verify(storage).storeRaw(eq(userId), any(), eq("mp4"), any(), eq(2048L));
        ordem.verify(repository).save(video);
        ordem.verify(publisher).publishUploaded(video);
    }

    @Test
    void naoTocaNoStorageQuandoOArquivoEInvalido() {
        assertThatThrownBy(() ->
                useCase.execute(userId, "aluno@fiap.com.br", "malware.exe", 10L, conteudo()))
                .isInstanceOf(InvalidVideoFileException.class);

        verify(storage, never()).storeRaw(any(), any(), anyString(), any(), anyLong());
        verify(repository, never()).save(any());
        verify(publisher, never()).publishUploaded(any());
    }

    @Test
    void naoTocaNoStorageQuandoOArquivoExcedeOLimite() {
        assertThatThrownBy(() -> useCase.execute(userId, "aluno@fiap.com.br",
                "grande.mp4", 300L * 1024 * 1024, conteudo()))
                .isInstanceOf(InvalidVideoFileException.class);

        verify(storage, never()).storeRaw(any(), any(), anyString(), any(), anyLong());
    }

    @Test
    void persisteAntesDePublicarParaNaoPerderOEstado() {
        ArgumentCaptor<Video> captor = ArgumentCaptor.forClass(Video.class);

        useCase.execute(userId, "aluno@fiap.com.br", "clipe.mp4", 2048L, conteudo());

        verify(repository).save(captor.capture());
        assertThat(captor.getValue().status()).isEqualTo(VideoStatus.PENDING);
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*SubmitVideoUseCaseTest'`
Expected: FAIL — `SubmitVideoUseCase` e `VideoEventPublisher` não existem.

- [ ] **Step 3: Implementar o port e o use case**

`application/port/out/VideoEventPublisher.java`:
```java
package br.com.fiapx.video.application.port.out;

import br.com.fiapx.video.domain.Video;

public interface VideoEventPublisher {
    void publishUploaded(Video video);
}
```

`application/usecase/SubmitVideoUseCase.java`:
```java
package br.com.fiapx.video.application.usecase;

import br.com.fiapx.video.application.port.out.VideoEventPublisher;
import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.application.port.out.VideoStorage;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoFile;
import org.springframework.stereotype.Service;

import java.io.InputStream;
import java.util.UUID;

@Service
public class SubmitVideoUseCase {

    private final VideoRepository repository;
    private final VideoStorage storage;
    private final VideoEventPublisher publisher;

    public SubmitVideoUseCase(VideoRepository repository, VideoStorage storage,
                              VideoEventPublisher publisher) {
        this.repository = repository;
        this.storage = storage;
        this.publisher = publisher;
    }

    public Video execute(UUID userId, String userEmail, String filename,
                         long sizeBytes, InputStream content) {
        VideoFile file = new VideoFile(filename, sizeBytes);
        UUID videoId = UUID.randomUUID();

        String rawKey = storage.storeRaw(userId, videoId, file.extension(), content, sizeBytes);

        Video video = Video.rehydrate(videoId, userId, userEmail, file.filename(), file.sizeBytes(),
                rawKey, br.com.fiapx.video.domain.VideoStatus.PENDING,
                null, null, null, null, 0, java.time.Instant.now(), null, null);

        repository.save(video);
        publisher.publishUploaded(video);
        return video;
    }
}
```

> Usamos `rehydrate` em vez de `submit` porque o `videoId` precisa existir **antes**
> da gravação no S3, para compor a chave. `Video.submit` continua sendo a fábrica usada
> nos testes de domínio e por qualquer chamador que não precise da chave antecipadamente.

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*SubmitVideoUseCaseTest'`
Expected: PASS — 4 testes verdes.

- [ ] **Step 5: Escrever o teste de integração do publisher (falha)**

```java
package br.com.fiapx.video.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.EventType;
import br.com.fiapx.contracts.VideoUploadedPayload;
import br.com.fiapx.video.application.port.out.VideoEventPublisher;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoFile;
import br.com.fiapx.video.support.LocalStackTestContainer;
import br.com.fiapx.video.support.PostgresTestContainer;
import com.fasterxml.jackson.core.type.TypeReference;
import io.awspring.cloud.sqs.operations.SqsTemplate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.TestPropertySource;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;

import java.time.Duration;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@Import({LocalStackTestContainer.class, PostgresTestContainer.class})
@TestPropertySource(properties = "spring.security.oauth2.resourceserver.jwt.jwk-set-uri=http://localhost:0/jwks")
class SqsVideoEventPublisherIT {

    @Autowired
    VideoEventPublisher publisher;

    @Autowired
    SqsTemplate sqsTemplate;

    // O spring-cloud-aws autoconfigura só o cliente assíncrono do SQS.
    @Autowired
    SqsAsyncClient sqsClient;

    @Value("${fiapx.sqs.processing-queue}")
    String fila;

    @BeforeEach
    void criarFila() {
        sqsClient.createQueue(b -> b.queueName(fila)).join();
    }

    @Test
    void publicaVideoUploadedComOEnvelopeCompleto() throws Exception {
        UUID userId = UUID.randomUUID();
        var video = Video.submit(userId, "aluno@fiap.com.br",
                new VideoFile("clipe.mp4", 2048L), "raw/u/v.mp4");

        publisher.publishUploaded(video);

        String corpo = sqsTemplate.receive(from -> from.queue(fila)
                        .pollTimeout(Duration.ofSeconds(10)), String.class)
                .orElseThrow()
                .getPayload();

        var envelope = ContractsJson.mapper()
                .readValue(corpo, new TypeReference<EventEnvelope<VideoUploadedPayload>>() {});

        assertThat(envelope.eventType()).isEqualTo(EventType.VIDEO_UPLOADED);
        assertThat(envelope.correlationId()).isEqualTo(video.id());
        assertThat(envelope.payload().videoId()).isEqualTo(video.id());
        assertThat(envelope.payload().userId()).isEqualTo(userId);
        assertThat(envelope.payload().userEmail()).isEqualTo("aluno@fiap.com.br");
        assertThat(envelope.payload().s3RawKey()).isEqualTo("raw/u/v.mp4");
        assertThat(envelope.payload().originalFilename()).isEqualTo("clipe.mp4");
        assertThat(envelope.payload().sizeBytes()).isEqualTo(2048L);
    }
}
```

- [ ] **Step 6: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*SqsVideoEventPublisherIT'`
Expected: FAIL — `SqsVideoEventPublisher` não existe.

- [ ] **Step 7: Implementar o publisher**

`infrastructure/messaging/SqsVideoEventPublisher.java`:
```java
package br.com.fiapx.video.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.EventType;
import br.com.fiapx.contracts.VideoUploadedPayload;
import br.com.fiapx.video.application.port.out.VideoEventPublisher;
import br.com.fiapx.video.domain.Video;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.awspring.cloud.sqs.operations.SqsTemplate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
class SqsVideoEventPublisher implements VideoEventPublisher {

    private static final Logger log = LoggerFactory.getLogger(SqsVideoEventPublisher.class);

    private final SqsTemplate sqsTemplate;
    private final ObjectMapper mapper = ContractsJson.mapper();
    private final String queue;

    SqsVideoEventPublisher(SqsTemplate sqsTemplate,
                           @Value("${fiapx.sqs.processing-queue}") String queue) {
        this.sqsTemplate = sqsTemplate;
        this.queue = queue;
    }

    @Override
    public void publishUploaded(Video video) {
        var payload = new VideoUploadedPayload(
                video.id(), video.userId(), video.userEmail(),
                video.s3RawKey(), video.originalFilename(), video.sizeBytes());

        var envelope = EventEnvelope.of(EventType.VIDEO_UPLOADED, video.id(), payload);

        try {
            // Serializa fora do lambda: a JsonProcessingException é checada e o Consumer não a propaga.
            String json = mapper.writeValueAsString(envelope);
            sqsTemplate.send(to -> to.queue(queue).payload(json));
            log.info("Evento VideoUploaded publicado correlationId={}", video.id());
        } catch (Exception ex) {
            throw new IllegalStateException("Falha ao publicar VideoUploaded para " + video.id(), ex);
        }
    }
}
```

- [ ] **Step 8: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*SqsVideoEventPublisherIT'`
Expected: PASS — a mensagem chega à fila com o envelope completo.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: submissao de video grava no S3 e publica na fila

O use case valida o arquivo antes de qualquer efeito colateral e persiste
PENDING antes de publicar, para que uma falha de publicacao deixe rastro
no banco em vez de sumir."
```

---

## Task 12: `video-api` — segurança JWT e endpoint de upload

**Files:**
- Create: `src/main/java/br/com/fiapx/video/infrastructure/config/SecurityConfig.java`
- Create: `src/main/java/br/com/fiapx/video/infrastructure/web/{AuthenticatedUser,VideoController,VideoResponse,ApiExceptionHandler}.java`
- Test: `src/test/java/br/com/fiapx/video/infrastructure/web/VideoControllerUploadTest.java`

**Interfaces:**
- Consumes: `SubmitVideoUseCase` (Task 11); `Video`, `VideoStatus` (Task 8).
- Produces:
  - `AuthenticatedUser.from(Jwt jwt)` → `AuthenticatedUser(UUID id, String email)`
  - `VideoResponse` — corpo de resposta: `id`, `originalFilename`, `status`, `frameCount`, `errorCode`, `errorMessage`, `createdAt`, `finishedAt`
  - `POST /api/v1/videos` → `202` com `VideoResponse`

- [ ] **Step 1: Escrever o teste do endpoint (falha)**

```java
package br.com.fiapx.video.infrastructure.web;

import br.com.fiapx.video.application.usecase.SubmitVideoUseCase;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoFile;
import br.com.fiapx.video.domain.exception.InvalidVideoFileException;
import br.com.fiapx.video.infrastructure.config.SecurityConfig;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.MockMvc;

import java.io.InputStream;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(VideoController.class)
@Import({SecurityConfig.class, ApiExceptionHandler.class})
class VideoControllerUploadTest {

    @Autowired
    MockMvc mockMvc;

    @MockBean
    SubmitVideoUseCase submitVideo;

    @MockBean
    org.springframework.security.oauth2.jwt.JwtDecoder jwtDecoder;

    private final UUID userId = UUID.randomUUID();

    private MockMultipartFile arquivo() {
        return new MockMultipartFile("video", "clipe.mp4", "video/mp4", new byte[]{1, 2, 3});
    }

    @Test
    void retorna202ComOIdEOStatusPending() throws Exception {
        var video = Video.submit(userId, "aluno@fiap.com.br",
                new VideoFile("clipe.mp4", 3L), "raw/u/v.mp4");
        when(submitVideo.execute(any(), anyString(), anyString(), anyLong(), any(InputStream.class)))
                .thenReturn(video);

        mockMvc.perform(multipart("/api/v1/videos").file(arquivo())
                        .with(jwt().jwt(j -> j.subject(userId.toString()).claim("email", "aluno@fiap.com.br"))))
                .andExpect(status().isAccepted())
                .andExpect(jsonPath("$.id").value(video.id().toString()))
                .andExpect(jsonPath("$.status").value("PENDING"))
                .andExpect(jsonPath("$.originalFilename").value("clipe.mp4"));

        verify(submitVideo).execute(eq(userId), eq("aluno@fiap.com.br"),
                eq("clipe.mp4"), eq(3L), any(InputStream.class));
    }

    @Test
    void retorna401SemToken() throws Exception {
        mockMvc.perform(multipart("/api/v1/videos").file(arquivo()))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void retorna400EmProblemJsonParaFormatoInvalido() throws Exception {
        when(submitVideo.execute(any(), anyString(), anyString(), anyLong(), any(InputStream.class)))
                .thenThrow(new InvalidVideoFileException("Formato nao suportado"));

        mockMvc.perform(multipart("/api/v1/videos")
                        .file(new MockMultipartFile("video", "doc.pdf", "application/pdf", new byte[]{1}))
                        .with(jwt().jwt(j -> j.subject(userId.toString()).claim("email", "a@b.com"))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.title").value("Formato nao suportado"));
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*VideoControllerUploadTest'`
Expected: FAIL — `VideoController` e `SecurityConfig` não existem.

- [ ] **Step 3: Implementar `SecurityConfig` e `AuthenticatedUser`**

`infrastructure/config/SecurityConfig.java`:
```java
package br.com.fiapx.video.infrastructure.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
public class SecurityConfig {

    @Bean
    SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        return http
                .csrf(csrf -> csrf.disable())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers("/actuator/**", "/swagger-ui/**", "/v3/api-docs/**").permitAll()
                        .anyRequest().authenticated())
                .oauth2ResourceServer(oauth -> oauth.jwt(jwt -> {
                }))
                .build();
    }
}
```

`infrastructure/web/AuthenticatedUser.java`:
```java
package br.com.fiapx.video.infrastructure.web;

import org.springframework.security.oauth2.jwt.Jwt;

import java.util.UUID;

public record AuthenticatedUser(UUID id, String email) {

    public static AuthenticatedUser from(Jwt jwt) {
        return new AuthenticatedUser(
                UUID.fromString(jwt.getSubject()),
                jwt.getClaimAsString("email"));
    }
}
```

- [ ] **Step 4: Implementar `VideoResponse`, `VideoController` e `ApiExceptionHandler`**

`infrastructure/web/VideoResponse.java`:
```java
package br.com.fiapx.video.infrastructure.web;

import br.com.fiapx.video.domain.Video;

import java.time.Instant;
import java.util.UUID;

public record VideoResponse(
        UUID id,
        String originalFilename,
        String status,
        Integer frameCount,
        String errorCode,
        String errorMessage,
        Instant createdAt,
        Instant finishedAt) {

    static VideoResponse from(Video video) {
        return new VideoResponse(
                video.id(),
                video.originalFilename(),
                video.status().name(),
                video.frameCount(),
                video.errorCode() == null ? null : video.errorCode().name(),
                video.errorMessage(),
                video.createdAt(),
                video.finishedAt());
    }
}
```

`infrastructure/web/VideoController.java` (os endpoints de leitura entram na Task 13):
```java
package br.com.fiapx.video.infrastructure.web;

import br.com.fiapx.video.application.usecase.SubmitVideoUseCase;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.io.UncheckedIOException;

@RestController
@RequestMapping("/api/v1/videos")
public class VideoController {

    private final SubmitVideoUseCase submitVideo;

    public VideoController(SubmitVideoUseCase submitVideo) {
        this.submitVideo = submitVideo;
    }

    @PostMapping
    public ResponseEntity<VideoResponse> upload(@AuthenticationPrincipal Jwt jwt,
                                                @RequestParam("video") MultipartFile file) {
        AuthenticatedUser user = AuthenticatedUser.from(jwt);
        try {
            var video = submitVideo.execute(user.id(), user.email(),
                    file.getOriginalFilename(), file.getSize(), file.getInputStream());
            return ResponseEntity.status(HttpStatus.ACCEPTED).body(VideoResponse.from(video));
        } catch (IOException ex) {
            throw new UncheckedIOException("Falha ao ler o arquivo enviado", ex);
        }
    }
}
```

`infrastructure/web/ApiExceptionHandler.java`:
```java
package br.com.fiapx.video.infrastructure.web;

import br.com.fiapx.video.application.exception.StorageException;
import br.com.fiapx.video.domain.exception.InvalidVideoFileException;
import br.com.fiapx.video.domain.exception.VideoNotFoundException;
import br.com.fiapx.video.domain.exception.VideoNotReadyException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.multipart.MaxUploadSizeExceededException;

@RestControllerAdvice
public class ApiExceptionHandler {

    @ExceptionHandler(InvalidVideoFileException.class)
    ProblemDetail onInvalidFile(InvalidVideoFileException ex) {
        return problem(HttpStatus.BAD_REQUEST, ex.getMessage());
    }

    @ExceptionHandler(MaxUploadSizeExceededException.class)
    ProblemDetail onTooLarge(MaxUploadSizeExceededException ex) {
        return problem(HttpStatus.PAYLOAD_TOO_LARGE, "Arquivo excede o limite de 200 MB");
    }

    @ExceptionHandler(VideoNotFoundException.class)
    ProblemDetail onNotFound(VideoNotFoundException ex) {
        return problem(HttpStatus.NOT_FOUND, ex.getMessage());
    }

    @ExceptionHandler(VideoNotReadyException.class)
    ProblemDetail onNotReady(VideoNotReadyException ex) {
        return problem(HttpStatus.CONFLICT, ex.getMessage());
    }

    @ExceptionHandler(StorageException.class)
    ProblemDetail onStorage(StorageException ex) {
        return problem(HttpStatus.SERVICE_UNAVAILABLE, "Armazenamento indisponivel");
    }

    private ProblemDetail problem(HttpStatus status, String title) {
        ProblemDetail problem = ProblemDetail.forStatus(status);
        problem.setTitle(title);
        problem.setDetail(title);
        return problem;
    }
}
```

- [ ] **Step 5: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*VideoControllerUploadTest'`
Expected: PASS — 202 com token válido, 401 sem token, 400 em problem+json para formato inválido.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: upload autenticado retornando 202 Accepted

O endpoint nao espera o processamento: grava, enfileira e devolve o id.
E esse desacoplamento que garante nao perder requisicao em pico."
```

---

## Task 13: `video-api` — listagem, detalhe e download

Os três endpoints de leitura. É aqui que o isolamento entre usuários é garantido.

**Files:**
- Create: `src/main/java/br/com/fiapx/video/application/usecase/{ListUserVideosUseCase,GetVideoUseCase,GenerateDownloadLinkUseCase}.java`
- Create: `src/main/java/br/com/fiapx/video/application/DownloadLink.java`
- Create: `src/main/java/br/com/fiapx/video/infrastructure/web/{VideoPageResponse,DownloadResponse}.java`
- Modify: `src/main/java/br/com/fiapx/video/infrastructure/web/VideoController.java`
- Test: `src/test/java/br/com/fiapx/video/application/usecase/{GetVideoUseCaseTest,GenerateDownloadLinkUseCaseTest}.java`
- Test: `src/test/java/br/com/fiapx/video/infrastructure/web/VideoControllerReadTest.java`

**Interfaces:**
- Consumes: `VideoRepository` (Task 9); `VideoStorage` (Task 10); `VideoResponse`, `AuthenticatedUser` (Task 12).
- Produces:
  - `ListUserVideosUseCase.execute(UUID userId, VideoStatus status, int page, int size)` → `List<Video>`
  - `ListUserVideosUseCase.count(UUID userId)` → `long`
  - `GetVideoUseCase.execute(UUID videoId, UUID userId)` → `Video` (lança `VideoNotFoundException`)
  - `GenerateDownloadLinkUseCase.execute(UUID videoId, UUID userId)` → `DownloadLink(String url, Instant expiresAt)`
  - `GET /api/v1/videos`, `GET /api/v1/videos/{id}`, `GET /api/v1/videos/{id}/download`

- [ ] **Step 1: Escrever os testes dos use cases (falham)**

`GetVideoUseCaseTest.java`:
```java
package br.com.fiapx.video.application.usecase;

import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoFile;
import br.com.fiapx.video.domain.exception.VideoNotFoundException;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GetVideoUseCaseTest {

    private final VideoRepository repository = mock(VideoRepository.class);
    private final GetVideoUseCase useCase = new GetVideoUseCase(repository);

    @Test
    void devolveOVideoDoProprioUsuario() {
        UUID userId = UUID.randomUUID();
        var video = Video.submit(userId, "a@b.com", new VideoFile("v.mp4", 10L), "raw/u/v.mp4");
        when(repository.findByIdAndUserId(video.id(), userId)).thenReturn(Optional.of(video));

        assertThat(useCase.execute(video.id(), userId).id()).isEqualTo(video.id());
    }

    @Test
    void videoDeOutroUsuarioResultaEmNotFoundNaoEmForbidden() {
        when(repository.findByIdAndUserId(any(), any())).thenReturn(Optional.empty());

        assertThatThrownBy(() -> useCase.execute(UUID.randomUUID(), UUID.randomUUID()))
                .isInstanceOf(VideoNotFoundException.class);
    }
}
```

`GenerateDownloadLinkUseCaseTest.java`:
```java
package br.com.fiapx.video.application.usecase;

import br.com.fiapx.video.application.DownloadLink;
import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.application.port.out.VideoStorage;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoFile;
import br.com.fiapx.video.domain.exception.VideoNotFoundException;
import br.com.fiapx.video.domain.exception.VideoNotReadyException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.net.URL;
import java.time.Duration;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GenerateDownloadLinkUseCaseTest {

    private VideoRepository repository;
    private VideoStorage storage;
    private GenerateDownloadLinkUseCase useCase;

    private final UUID userId = UUID.randomUUID();

    @BeforeEach
    void setUp() throws Exception {
        repository = mock(VideoRepository.class);
        storage = mock(VideoStorage.class);
        useCase = new GenerateDownloadLinkUseCase(repository, storage, 15);
        when(storage.presignedDownloadUrl(anyString(), any(Duration.class)))
                .thenReturn(new URL("https://s3.local/zip?X-Amz-Signature=abc"));
    }

    private Video concluido() {
        var video = Video.submit(userId, "a@b.com", new VideoFile("v.mp4", 10L), "raw/u/v.mp4");
        video.markProcessing();
        video.markCompleted("processed/u/v.zip", 12);
        return video;
    }

    @Test
    void geraLinkComExpiracaoParaVideoConcluido() {
        var video = concluido();
        when(repository.findByIdAndUserId(video.id(), userId)).thenReturn(Optional.of(video));

        DownloadLink link = useCase.execute(video.id(), userId);

        assertThat(link.url()).contains("X-Amz-Signature");
        assertThat(link.expiresAt()).isAfter(java.time.Instant.now());
        verify(storage).presignedDownloadUrl("processed/u/v.zip", Duration.ofMinutes(15));
    }

    @Test
    void recusaDownloadDeVideoAindaEmProcessamento() {
        var video = Video.submit(userId, "a@b.com", new VideoFile("v.mp4", 10L), "raw/u/v.mp4");
        video.markProcessing();
        when(repository.findByIdAndUserId(video.id(), userId)).thenReturn(Optional.of(video));

        assertThatThrownBy(() -> useCase.execute(video.id(), userId))
                .isInstanceOf(VideoNotReadyException.class);

        verify(storage, never()).presignedDownloadUrl(anyString(), any());
    }

    @Test
    void videoDeOutroUsuarioResultaEmNotFound() {
        when(repository.findByIdAndUserId(any(), any())).thenReturn(Optional.empty());

        assertThatThrownBy(() -> useCase.execute(UUID.randomUUID(), userId))
                .isInstanceOf(VideoNotFoundException.class);
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falham**

Run: `./mvnw test -Dtest='*UseCaseTest'`
Expected: FAIL — `GetVideoUseCase`, `GenerateDownloadLinkUseCase` e `DownloadLink` não existem.

- [ ] **Step 3: Implementar os três use cases**

`application/DownloadLink.java`:
```java
package br.com.fiapx.video.application;

import java.time.Instant;

public record DownloadLink(String url, Instant expiresAt) {
}
```

`application/usecase/GetVideoUseCase.java`:
```java
package br.com.fiapx.video.application.usecase;

import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.exception.VideoNotFoundException;
import org.springframework.stereotype.Service;

import java.util.UUID;

@Service
public class GetVideoUseCase {

    private final VideoRepository repository;

    public GetVideoUseCase(VideoRepository repository) {
        this.repository = repository;
    }

    public Video execute(UUID videoId, UUID userId) {
        return repository.findByIdAndUserId(videoId, userId)
                .orElseThrow(() -> new VideoNotFoundException("Video nao encontrado"));
    }
}
```

`application/usecase/ListUserVideosUseCase.java`:
```java
package br.com.fiapx.video.application.usecase;

import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoStatus;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.UUID;

@Service
public class ListUserVideosUseCase {

    private static final int MAX_PAGE_SIZE = 100;

    private final VideoRepository repository;

    public ListUserVideosUseCase(VideoRepository repository) {
        this.repository = repository;
    }

    public List<Video> execute(UUID userId, VideoStatus status, int page, int size) {
        int paginaSegura = Math.max(page, 0);
        int tamanhoSeguro = Math.clamp(size, 1, MAX_PAGE_SIZE);
        return repository.findByUserId(userId, status, paginaSegura, tamanhoSeguro);
    }

    public long count(UUID userId) {
        return repository.countByUserId(userId);
    }
}
```

`application/usecase/GenerateDownloadLinkUseCase.java`:
```java
package br.com.fiapx.video.application.usecase;

import br.com.fiapx.video.application.DownloadLink;
import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.application.port.out.VideoStorage;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoStatus;
import br.com.fiapx.video.domain.exception.VideoNotFoundException;
import br.com.fiapx.video.domain.exception.VideoNotReadyException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;
import java.util.UUID;

@Service
public class GenerateDownloadLinkUseCase {

    private final VideoRepository repository;
    private final VideoStorage storage;
    private final long ttlMinutes;

    public GenerateDownloadLinkUseCase(VideoRepository repository, VideoStorage storage,
                                       @Value("${fiapx.s3.presign-ttl-minutes}") long ttlMinutes) {
        this.repository = repository;
        this.storage = storage;
        this.ttlMinutes = ttlMinutes;
    }

    public DownloadLink execute(UUID videoId, UUID userId) {
        Video video = repository.findByIdAndUserId(videoId, userId)
                .orElseThrow(() -> new VideoNotFoundException("Video nao encontrado"));

        if (video.status() != VideoStatus.COMPLETED) {
            throw new VideoNotReadyException(
                    "O video ainda nao esta disponivel. Status atual: " + video.status());
        }

        Duration ttl = Duration.ofMinutes(ttlMinutes);
        String url = storage.presignedDownloadUrl(video.s3ZipKey(), ttl).toString();
        return new DownloadLink(url, Instant.now().plus(ttl));
    }
}
```

- [ ] **Step 4: Rodar e confirmar que passam**

Run: `./mvnw test -Dtest='*UseCaseTest'`
Expected: PASS — 5 testes verdes.

- [ ] **Step 5: Escrever o teste dos endpoints de leitura (falha)**

```java
package br.com.fiapx.video.infrastructure.web;

import br.com.fiapx.video.application.DownloadLink;
import br.com.fiapx.video.application.usecase.GenerateDownloadLinkUseCase;
import br.com.fiapx.video.application.usecase.GetVideoUseCase;
import br.com.fiapx.video.application.usecase.ListUserVideosUseCase;
import br.com.fiapx.video.application.usecase.SubmitVideoUseCase;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoFile;
import br.com.fiapx.video.domain.VideoStatus;
import br.com.fiapx.video.domain.exception.VideoNotFoundException;
import br.com.fiapx.video.infrastructure.config.SecurityConfig;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(VideoController.class)
@Import({SecurityConfig.class, ApiExceptionHandler.class})
class VideoControllerReadTest {

    @Autowired
    MockMvc mockMvc;

    @MockBean SubmitVideoUseCase submitVideo;
    @MockBean ListUserVideosUseCase listUserVideos;
    @MockBean GetVideoUseCase getVideo;
    @MockBean GenerateDownloadLinkUseCase generateDownloadLink;
    @MockBean org.springframework.security.oauth2.jwt.JwtDecoder jwtDecoder;

    private final UUID userId = UUID.randomUUID();

    private org.springframework.test.web.servlet.request.RequestPostProcessor comToken() {
        return jwt().jwt(j -> j.subject(userId.toString()).claim("email", "aluno@fiap.com.br"));
    }

    private Video concluido() {
        var video = Video.submit(userId, "aluno@fiap.com.br",
                new VideoFile("clipe.mp4", 10L), "raw/u/v.mp4");
        video.markProcessing();
        video.markCompleted("processed/u/v.zip", 12);
        return video;
    }

    @Test
    void listaOsVideosDoUsuarioComTotal() throws Exception {
        when(listUserVideos.execute(eq(userId), any(), anyInt(), anyInt()))
                .thenReturn(List.of(concluido()));
        when(listUserVideos.count(userId)).thenReturn(1L);

        mockMvc.perform(get("/api/v1/videos").with(comToken()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.total").value(1))
                .andExpect(jsonPath("$.items[0].status").value("COMPLETED"))
                .andExpect(jsonPath("$.items[0].frameCount").value(12));
    }

    @Test
    void repassaOFiltroDeStatus() throws Exception {
        when(listUserVideos.execute(eq(userId), eq(VideoStatus.FAILED), anyInt(), anyInt()))
                .thenReturn(List.of());
        when(listUserVideos.count(userId)).thenReturn(0L);

        mockMvc.perform(get("/api/v1/videos").param("status", "FAILED").with(comToken()))
                .andExpect(status().isOk());

        verify(listUserVideos).execute(eq(userId), eq(VideoStatus.FAILED), eq(0), eq(20));
    }

    @Test
    void retorna404ParaVideoDeOutroUsuario() throws Exception {
        when(getVideo.execute(any(), any())).thenThrow(new VideoNotFoundException("Video nao encontrado"));

        mockMvc.perform(get("/api/v1/videos/" + UUID.randomUUID()).with(comToken()))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.title").value("Video nao encontrado"));
    }

    @Test
    void devolveOLinkAssinadoDeDownload() throws Exception {
        var expira = Instant.now().plusSeconds(900);
        when(generateDownloadLink.execute(any(), eq(userId)))
                .thenReturn(new DownloadLink("https://s3.local/zip?X-Amz-Signature=abc", expira));

        mockMvc.perform(get("/api/v1/videos/" + UUID.randomUUID() + "/download").with(comToken()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.url").value("https://s3.local/zip?X-Amz-Signature=abc"))
                .andExpect(jsonPath("$.expiresAt").exists());
    }

    @Test
    void listagemExigeAutenticacao() throws Exception {
        mockMvc.perform(get("/api/v1/videos")).andExpect(status().isUnauthorized());
    }
}
```

- [ ] **Step 6: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*VideoControllerReadTest'`
Expected: FAIL — os endpoints de leitura ainda não existem no controller.

- [ ] **Step 7: Implementar os DTOs e os endpoints**

`infrastructure/web/VideoPageResponse.java`:
```java
package br.com.fiapx.video.infrastructure.web;

import java.util.List;

public record VideoPageResponse(List<VideoResponse> items, long total, int page, int size) {
}
```

`infrastructure/web/DownloadResponse.java`:
```java
package br.com.fiapx.video.infrastructure.web;

import br.com.fiapx.video.application.DownloadLink;

import java.time.Instant;

public record DownloadResponse(String url, Instant expiresAt) {
    static DownloadResponse from(DownloadLink link) {
        return new DownloadResponse(link.url(), link.expiresAt());
    }
}
```

Acrescente ao `VideoController` os endpoints abaixo, injetando os três use cases no
construtor. **Atualize também `VideoControllerUploadTest`** com os mocks que o novo
construtor exige, senão o teste da Task 12 para de subir o contexto:

```java
    @MockBean ListUserVideosUseCase listUserVideos;
    @MockBean GetVideoUseCase getVideo;
    @MockBean GenerateDownloadLinkUseCase generateDownloadLink;
```

Trechos a acrescentar no controller:
```java
    @GetMapping
    public VideoPageResponse list(@AuthenticationPrincipal Jwt jwt,
                                  @RequestParam(required = false) VideoStatus status,
                                  @RequestParam(defaultValue = "0") int page,
                                  @RequestParam(defaultValue = "20") int size) {
        UUID userId = AuthenticatedUser.from(jwt).id();
        var items = listUserVideos.execute(userId, status, page, size).stream()
                .map(VideoResponse::from)
                .toList();
        return new VideoPageResponse(items, listUserVideos.count(userId), page, size);
    }

    @GetMapping("/{id}")
    public VideoResponse detail(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID id) {
        return VideoResponse.from(getVideo.execute(id, AuthenticatedUser.from(jwt).id()));
    }

    @GetMapping("/{id}/download")
    public DownloadResponse download(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID id) {
        return DownloadResponse.from(
                generateDownloadLink.execute(id, AuthenticatedUser.from(jwt).id()));
    }
```

- [ ] **Step 8: Rodar a suíte inteira**

Run: `./mvnw verify`
Expected: PASS, incluindo a verificação de cobertura.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: listagem, detalhe e download assinado dos videos

Recurso de outro usuario responde 404 em vez de 403, para nao revelar a
existencia do id. O download so e liberado com o video em COMPLETED."
```

---

## Task 14: `video-api` — consumidor dos eventos de resultado

Fecha o ciclo: o worker publica no SNS, o `video-api` consome da `video-status-queue` e atualiza o banco. É onde a idempotência da máquina de estados é exercitada de verdade.

**Files:**
- Create: `src/main/java/br/com/fiapx/video/application/usecase/ApplyProcessingResultUseCase.java`
- Create: `src/main/java/br/com/fiapx/video/infrastructure/messaging/VideoStatusListener.java`
- Test: `src/test/java/br/com/fiapx/video/application/usecase/ApplyProcessingResultUseCaseTest.java`
- Test: `src/test/java/br/com/fiapx/video/infrastructure/messaging/VideoStatusListenerIT.java`

**Interfaces:**
- Consumes: `VideoRepository` (Task 9); `EventEnvelope`, `EventType`, `VideoProcessedPayload`, `VideoFailedPayload`, `VideoProcessingStartedPayload`, `ErrorCode` (Task 2).
- Produces:
  - `ApplyProcessingResultUseCase.onStarted(UUID videoId)`, `.onCompleted(UUID videoId, String s3ZipKey, int frameCount)`, `.onFailed(UUID videoId, ErrorCode code, String message)` — todos `void`, todos idempotentes.

- [ ] **Step 1: Escrever o teste do use case (falha)**

```java
package br.com.fiapx.video.application.usecase;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoFile;
import br.com.fiapx.video.domain.VideoStatus;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ApplyProcessingResultUseCaseTest {

    private VideoRepository repository;
    private ApplyProcessingResultUseCase useCase;
    private Video video;

    @BeforeEach
    void setUp() {
        repository = mock(VideoRepository.class);
        useCase = new ApplyProcessingResultUseCase(repository);
        video = Video.submit(UUID.randomUUID(), "a@b.com",
                new VideoFile("v.mp4", 10L), "raw/u/v.mp4");
        when(repository.findById(video.id())).thenReturn(Optional.of(video));
    }

    @Test
    void onStartedMovreParaProcessing() {
        useCase.onStarted(video.id());

        assertThat(video.status()).isEqualTo(VideoStatus.PROCESSING);
        verify(repository).save(video);
    }

    @Test
    void onCompletedGravaZipEFrames() {
        useCase.onStarted(video.id());
        useCase.onCompleted(video.id(), "processed/u/v.zip", 42);

        assertThat(video.status()).isEqualTo(VideoStatus.COMPLETED);
        assertThat(video.frameCount()).isEqualTo(42);
        verify(repository, times(2)).save(video);
    }

    @Test
    void onFailedGravaCodigoEMensagem() {
        useCase.onStarted(video.id());
        useCase.onFailed(video.id(), ErrorCode.TIMEOUT, "estourou 10 min");

        assertThat(video.status()).isEqualTo(VideoStatus.FAILED);
        assertThat(video.errorCode()).isEqualTo(ErrorCode.TIMEOUT);
    }

    @Test
    void entregaDuplicadaNaoPersisteDeNovo() {
        useCase.onStarted(video.id());
        useCase.onCompleted(video.id(), "processed/u/v.zip", 42);

        useCase.onCompleted(video.id(), "processed/u/OUTRO.zip", 99);

        assertThat(video.s3ZipKey()).isEqualTo("processed/u/v.zip");
        assertThat(video.frameCount()).isEqualTo(42);
        verify(repository, times(2)).save(video);
    }

    @Test
    void eventoDeVideoInexistenteNaoQuebraOConsumidor() {
        when(repository.findById(any())).thenReturn(Optional.empty());

        assertThatCode(() -> useCase.onCompleted(UUID.randomUUID(), "k.zip", 1))
                .doesNotThrowAnyException();

        verify(repository, never()).save(any());
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*ApplyProcessingResultUseCaseTest'`
Expected: FAIL — `ApplyProcessingResultUseCase` não existe.

- [ ] **Step 3: Implementar o use case**

```java
package br.com.fiapx.video.application.usecase;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.domain.Video;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.Optional;
import java.util.UUID;
import java.util.function.Predicate;

@Service
public class ApplyProcessingResultUseCase {

    private static final Logger log = LoggerFactory.getLogger(ApplyProcessingResultUseCase.class);

    private final VideoRepository repository;

    public ApplyProcessingResultUseCase(VideoRepository repository) {
        this.repository = repository;
    }

    public void onStarted(UUID videoId) {
        apply(videoId, Video::markProcessing, "VideoProcessingStarted");
    }

    public void onCompleted(UUID videoId, String s3ZipKey, int frameCount) {
        apply(videoId, video -> video.markCompleted(s3ZipKey, frameCount), "VideoProcessed");
    }

    public void onFailed(UUID videoId, ErrorCode errorCode, String errorMessage) {
        apply(videoId, video -> video.markFailed(errorCode, errorMessage), "VideoFailed");
    }

    /**
     * Aplica a transição e persiste apenas se ela foi aceita. Evento para vídeo
     * inexistente ou transição proibida é registrado e descartado — nunca lança,
     * para que o SQS não devolva a mensagem à fila indefinidamente.
     */
    private void apply(UUID videoId, Predicate<Video> transicao, String evento) {
        Optional<Video> encontrado = repository.findById(videoId);

        if (encontrado.isEmpty()) {
            log.warn("Evento {} ignorado: video {} nao encontrado", evento, videoId);
            return;
        }

        Video video = encontrado.get();
        if (transicao.test(video)) {
            repository.save(video);
            log.info("Evento {} aplicado correlationId={} novoStatus={}",
                    evento, videoId, video.status());
        } else {
            log.warn("Evento {} ignorado por transicao proibida correlationId={} statusAtual={}",
                    evento, videoId, video.status());
        }
    }
}
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*ApplyProcessingResultUseCaseTest'`
Expected: PASS — 5 testes verdes.

- [ ] **Step 5: Escrever o teste de integração do listener (falha)**

```java
package br.com.fiapx.video.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.EventType;
import br.com.fiapx.contracts.VideoProcessedPayload;
import br.com.fiapx.video.application.port.out.VideoRepository;
import br.com.fiapx.video.domain.Video;
import br.com.fiapx.video.domain.VideoFile;
import br.com.fiapx.video.domain.VideoStatus;
import br.com.fiapx.video.support.LocalStackTestContainer;
import br.com.fiapx.video.support.PostgresTestContainer;
import io.awspring.cloud.sqs.operations.SqsTemplate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.TestPropertySource;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;

import java.time.Duration;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

@SpringBootTest
@Import({LocalStackTestContainer.class, PostgresTestContainer.class})
@TestPropertySource(properties = "spring.security.oauth2.resourceserver.jwt.jwk-set-uri=http://localhost:0/jwks")
class VideoStatusListenerIT {

    @Autowired VideoRepository repository;
    @Autowired SqsTemplate sqsTemplate;
    @Autowired SqsAsyncClient sqsClient; // o spring-cloud-aws só autoconfigura o cliente assíncrono

    @Value("${fiapx.sqs.status-queue}")
    String fila;

    @BeforeEach
    void criarFila() {
        sqsClient.createQueue(b -> b.queueName(fila)).join();
    }

    @Test
    void consomeVideoProcessedEMarcaOVideoComoCompleted() throws Exception {
        var video = Video.submit(UUID.randomUUID(), "a@b.com",
                new VideoFile("v.mp4", 10L), "raw/u/v.mp4");
        video.markProcessing();
        repository.save(video);

        var envelope = EventEnvelope.of(EventType.VIDEO_PROCESSED, video.id(),
                new VideoProcessedPayload(video.id(), video.userId(), "processed/u/v.zip", 42, 1500L));

        // Serializa fora do lambda: a JsonProcessingException é checada e o Consumer não a propaga.
        String json = ContractsJson.mapper().writeValueAsString(envelope);
        sqsTemplate.send(to -> to.queue(fila).payload(json));

        await().atMost(Duration.ofSeconds(20)).untilAsserted(() -> {
            var atualizado = repository.findById(video.id()).orElseThrow();
            assertThat(atualizado.status()).isEqualTo(VideoStatus.COMPLETED);
            assertThat(atualizado.frameCount()).isEqualTo(42);
            assertThat(atualizado.s3ZipKey()).isEqualTo("processed/u/v.zip");
        });
    }
}
```

Adicione ao `pom.xml` (versão gerenciada pelo Spring Boot):

```xml
<dependency>
    <groupId>org.awaitility</groupId>
    <artifactId>awaitility</artifactId>
    <scope>test</scope>
</dependency>
```

- [ ] **Step 6: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*VideoStatusListenerIT'`
Expected: FAIL — o listener não existe, o vídeo continua em `PROCESSING`.

- [ ] **Step 7: Implementar o listener**

```java
package br.com.fiapx.video.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.VideoFailedPayload;
import br.com.fiapx.contracts.VideoProcessedPayload;
import br.com.fiapx.contracts.VideoProcessingStartedPayload;
import br.com.fiapx.video.application.usecase.ApplyProcessingResultUseCase;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.awspring.cloud.sqs.annotation.SqsListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

@Component
class VideoStatusListener {

    private static final Logger log = LoggerFactory.getLogger(VideoStatusListener.class);

    private final ApplyProcessingResultUseCase useCase;
    private final ObjectMapper mapper = ContractsJson.mapper();

    VideoStatusListener(ApplyProcessingResultUseCase useCase) {
        this.useCase = useCase;
    }

    @SqsListener("${fiapx.sqs.status-queue}")
    void onMessage(String body) throws Exception {
        JsonNode raiz = mapper.readTree(body);

        // Uma assinatura SNS→SQS sem raw delivery embrulha o payload em "Message".
        if (raiz.has("Message") && raiz.has("TopicArn")) {
            raiz = mapper.readTree(raiz.get("Message").asText());
        }

        String tipo = raiz.get("eventType").asText();
        switch (tipo) {
            case "VideoProcessingStarted" -> {
                var evento = mapper.treeToValue(raiz,
                        mapper.getTypeFactory().constructParametricType(
                                EventEnvelope.class, VideoProcessingStartedPayload.class));
                var envelope = (EventEnvelope<VideoProcessingStartedPayload>) evento;
                useCase.onStarted(envelope.payload().videoId());
            }
            case "VideoProcessed" -> {
                var evento = mapper.treeToValue(raiz,
                        mapper.getTypeFactory().constructParametricType(
                                EventEnvelope.class, VideoProcessedPayload.class));
                var envelope = (EventEnvelope<VideoProcessedPayload>) evento;
                useCase.onCompleted(envelope.payload().videoId(),
                        envelope.payload().s3ZipKey(), envelope.payload().frameCount());
            }
            case "VideoFailed" -> {
                var evento = mapper.treeToValue(raiz,
                        mapper.getTypeFactory().constructParametricType(
                                EventEnvelope.class, VideoFailedPayload.class));
                var envelope = (EventEnvelope<VideoFailedPayload>) evento;
                useCase.onFailed(envelope.payload().videoId(),
                        envelope.payload().errorCode(), envelope.payload().errorMessage());
            }
            default -> log.warn("Evento ignorado, tipo desconhecido: {}", tipo);
        }
    }
}
```

- [ ] **Step 8: Rodar a suíte inteira**

Run: `./mvnw verify`
Expected: PASS — inclusive o `VideoStatusListenerIT`.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: consumidor dos eventos de resultado do processamento

Trata envelope SNS embrulhado e nao lanca excecao para evento orfao ou
transicao proibida, evitando que uma mensagem ruim fique reciclando na fila."
```

---

## Task 15: `video-api` — Dockerfile e README

**Files:**
- Create: `services/fiapx-video-api/{Dockerfile,.dockerignore,README.md}`

**Interfaces:**
- Consumes: o jar de `fiapx-contracts` (Task 2), que precisa estar disponível no build.
- Produces: imagem `fiapx/video-api:local`, usada na Task 20.

- [ ] **Step 1: Escrever o `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
# O contexto de build precisa ser services/, para alcançar fiapx-contracts:
#   docker build -f fiapx-video-api/Dockerfile -t fiapx/video-api:local ..
FROM maven:3.9-eclipse-temurin-21-alpine AS build
WORKDIR /workspace

COPY fiapx-contracts/pom.xml /workspace/fiapx-contracts/pom.xml
COPY fiapx-contracts/src /workspace/fiapx-contracts/src
RUN mvn -B -q -f /workspace/fiapx-contracts/pom.xml install -DskipTests

COPY fiapx-video-api/pom.xml /workspace/app/
WORKDIR /workspace/app
RUN mvn -B -q dependency:go-offline || true
COPY fiapx-video-api/src /workspace/app/src
RUN mvn -B -q package -DskipTests

FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S fiapx && adduser -S fiapx -G fiapx
WORKDIR /app
COPY --from=build /workspace/app/target/*.jar app.jar
USER fiapx
EXPOSE 8082
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75"
HEALTHCHECK --interval=10s --timeout=3s --start-period=60s --retries=6 \
  CMD wget -qO- http://localhost:8082/actuator/health/readiness | grep -q UP || exit 1
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

- [ ] **Step 2: Escrever o `.dockerignore`**

```
.git
target
*.md
```

- [ ] **Step 3: Construir a imagem**

```bash
cd services
docker build -f fiapx-video-api/Dockerfile -t fiapx/video-api:local .
```
Expected: build conclui; `docker images fiapx/video-api:local` lista a imagem.

- [ ] **Step 4: Escrever o `README.md`**

```markdown
# fiapx-video-api

Recebe o upload, publica na fila de processamento e expõe o status e o download.

| Método | Rota | Descrição |
|---|---|---|
| POST | `/api/v1/videos` | multipart `video`. Responde `202` com o `videoId` |
| GET | `/api/v1/videos` | `?status=&page=&size=` — apenas os vídeos do token |
| GET | `/api/v1/videos/{id}` | Detalhe. `404` se não pertencer ao usuário |
| GET | `/api/v1/videos/{id}/download` | URL assinada do S3, válida por 15 min |

Consome `video-status-queue` para atualizar `PENDING → PROCESSING → COMPLETED/FAILED`.

## Rodar os testes

    ./mvnw verify

Requer Docker: Testcontainers sobe PostgreSQL 16 e LocalStack (S3, SQS, SNS).

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `DB_URL` | `jdbc:postgresql://localhost:5432/video_db` | JDBC |
| `JWKS_URI` | `http://localhost:8081/.well-known/jwks.json` | Chave pública do auth-service |
| `S3_BUCKET` | `fiapx-videos` | Bucket |
| `SQS_PROCESSING_QUEUE` | `video-processing-queue` | Fila de saída |
| `SQS_STATUS_QUEUE` | `video-status-queue` | Fila de entrada |
| `AWS_ENDPOINT` | vazio | Aponte para o LocalStack no ambiente local |
| `S3_PATH_STYLE` | `false` | `true` no LocalStack, onde o host virtual do bucket não resolve |
| `S3_PUBLIC_ENDPOINT` | vazio | Host da URL assinada entregue ao navegador; no Compose, `http://localhost:4566` |
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "build: imagem do video-api com o jar de contratos

O build multi-stage instala fiapx-contracts no repositorio Maven local do
estagio de build, evitando depender de um registry na fase 1."
```

---

## Task 16: `processing-worker` — esqueleto, ports e compactação em ZIP

**Files:**
- Create: `services/fiapx-processing-worker/pom.xml`
- Create: `src/main/java/br/com/fiapx/worker/WorkerApplication.java`
- Create: `src/main/java/br/com/fiapx/worker/application/exception/ProcessingException.java`
- Create: `src/main/java/br/com/fiapx/worker/application/port/out/{VideoObjectStorage,FrameExtractor,ArchiveWriter,ProcessingEventPublisher}.java`
- Create: `src/main/java/br/com/fiapx/worker/infrastructure/archive/ZipArchiveWriter.java`
- Test: `src/test/java/br/com/fiapx/worker/infrastructure/archive/ZipArchiveWriterTest.java`

**Interfaces:**
- Consumes: `ErrorCode` (Task 2).
- Produces:
  - `ProcessingException(ErrorCode errorCode, String message)` com `errorCode()`
  - `VideoObjectStorage`: `void download(String key, Path target)`, `String uploadZip(UUID userId, UUID videoId, Path zip)`
  - `FrameExtractor`: `List<Path> extract(Path video, Path outputDir)`
  - `ArchiveWriter`: `void write(List<Path> files, Path target)`
  - `ProcessingEventPublisher`: `void publishStarted(UUID videoId, UUID userId, int attempt)`, `void publishProcessed(UUID videoId, UUID userId, String s3ZipKey, int frameCount, long millis)`, `void publishFailed(UUID videoId, UUID userId, String userEmail, ErrorCode code, String message, int attempt)`

- [ ] **Step 1: Criar o repositório, o Maven wrapper e o `pom.xml`**

```bash
cd services && mkdir -p fiapx-processing-worker && cd fiapx-processing-worker && git init
cp -r ../fiapx-contracts/mvnw ../fiapx-contracts/mvnw.cmd ../fiapx-contracts/.mvn \
      ../fiapx-contracts/.gitattributes ../fiapx-contracts/.gitignore .
```

`pom.xml`:
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
    <artifactId>fiapx-processing-worker</artifactId>
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

        <!-- Web só para expor /actuator na porta 8083 (healthcheck, probes do K8s e
             scrape do Prometheus). O worker não tem controllers. -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-actuator</artifactId>
        </dependency>
        <dependency>
            <groupId>io.awspring.cloud</groupId>
            <artifactId>spring-cloud-aws-starter-sqs</artifactId>
        </dependency>
        <dependency>
            <groupId>io.awspring.cloud</groupId>
            <artifactId>spring-cloud-aws-starter-sns</artifactId>
        </dependency>
        <dependency>
            <groupId>io.awspring.cloud</groupId>
            <artifactId>spring-cloud-aws-starter-s3</artifactId>
        </dependency>
        <dependency>
            <groupId>software.amazon.awssdk</groupId>
            <artifactId>s3</artifactId>
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
                                        <include>br.com.fiapx.worker.application*</include>
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

- [ ] **Step 2: Escrever o teste do compactador (falha)**

```java
package br.com.fiapx.worker.infrastructure.archive;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import static org.assertj.core.api.Assertions.assertThat;

class ZipArchiveWriterTest {

    private final ZipArchiveWriter writer = new ZipArchiveWriter();

    @Test
    void compactaTodosOsArquivosSemDiretorios(@TempDir Path tmp) throws Exception {
        Path pastaFrames = Files.createDirectory(tmp.resolve("frames"));
        Path frame1 = Files.writeString(pastaFrames.resolve("frame_0001.png"), "png-1");
        Path frame2 = Files.writeString(pastaFrames.resolve("frame_0002.png"), "png-2");
        Path destino = tmp.resolve("frames.zip");

        writer.write(List.of(frame1, frame2), destino);

        List<String> nomes = new ArrayList<>();
        try (ZipFile zip = new ZipFile(destino.toFile())) {
            var entradas = zip.entries();
            while (entradas.hasMoreElements()) {
                ZipEntry entrada = entradas.nextElement();
                nomes.add(entrada.getName());
                assertThat(entrada.getMethod()).isEqualTo(ZipEntry.DEFLATED);
            }
            assertThat(new String(zip.getInputStream(zip.getEntry("frame_0001.png")).readAllBytes(),
                    StandardCharsets.UTF_8)).isEqualTo("png-1");
        }

        assertThat(nomes).containsExactlyInAnyOrder("frame_0001.png", "frame_0002.png");
        assertThat(nomes).allSatisfy(nome -> assertThat(nome).doesNotContain("/"));
    }

    @Test
    void ordenaAsEntradasPeloNome(@TempDir Path tmp) throws Exception {
        Path pasta = Files.createDirectory(tmp.resolve("frames"));
        Path terceiro = Files.writeString(pasta.resolve("frame_0003.png"), "c");
        Path primeiro = Files.writeString(pasta.resolve("frame_0001.png"), "a");
        Path destino = tmp.resolve("out.zip");

        writer.write(List.of(terceiro, primeiro), destino);

        try (ZipFile zip = new ZipFile(destino.toFile())) {
            assertThat(zip.stream().map(ZipEntry::getName).toList())
                    .containsExactly("frame_0001.png", "frame_0003.png");
        }
    }
}
```

- [ ] **Step 3: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*ZipArchiveWriterTest'`
Expected: FAIL — `ZipArchiveWriter` não existe.

- [ ] **Step 4: Implementar as exceções e os ports**

`application/exception/ProcessingException.java`:
```java
package br.com.fiapx.worker.application.exception;

import br.com.fiapx.contracts.ErrorCode;

public class ProcessingException extends RuntimeException {

    private final ErrorCode errorCode;

    public ProcessingException(ErrorCode errorCode, String message) {
        super(message);
        this.errorCode = errorCode;
    }

    public ProcessingException(ErrorCode errorCode, String message, Throwable cause) {
        super(message, cause);
        this.errorCode = errorCode;
    }

    public ErrorCode errorCode() {
        return errorCode;
    }
}
```

`application/port/out/VideoObjectStorage.java`:
```java
package br.com.fiapx.worker.application.port.out;

import java.nio.file.Path;
import java.util.UUID;

public interface VideoObjectStorage {

    void download(String key, Path target);

    /** @return a chave S3 do ZIP gravado. */
    String uploadZip(UUID userId, UUID videoId, Path zip);
}
```

`application/port/out/FrameExtractor.java`:
```java
package br.com.fiapx.worker.application.port.out;

import java.nio.file.Path;
import java.util.List;

public interface FrameExtractor {

    /** Extrai 1 frame por segundo em PNG. @return os frames, ordenados pelo nome. */
    List<Path> extract(Path video, Path outputDir);
}
```

`application/port/out/ArchiveWriter.java`:
```java
package br.com.fiapx.worker.application.port.out;

import java.nio.file.Path;
import java.util.List;

public interface ArchiveWriter {
    void write(List<Path> files, Path target);
}
```

`application/port/out/ProcessingEventPublisher.java`:
```java
package br.com.fiapx.worker.application.port.out;

import br.com.fiapx.contracts.ErrorCode;

import java.util.UUID;

public interface ProcessingEventPublisher {

    void publishStarted(UUID videoId, UUID userId, int attempt);

    void publishProcessed(UUID videoId, UUID userId, String s3ZipKey, int frameCount, long millis);

    void publishFailed(UUID videoId, UUID userId, String userEmail,
                       ErrorCode errorCode, String errorMessage, int attempt);
}
```

- [ ] **Step 5: Implementar `ZipArchiveWriter` e `WorkerApplication`**

`infrastructure/archive/ZipArchiveWriter.java`:
```java
package br.com.fiapx.worker.infrastructure.archive;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.worker.application.exception.ProcessingException;
import br.com.fiapx.worker.application.port.out.ArchiveWriter;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

@Component
public class ZipArchiveWriter implements ArchiveWriter {

    @Override
    public void write(List<Path> files, Path target) {
        List<Path> ordenados = files.stream()
                .sorted(Comparator.comparing(p -> p.getFileName().toString()))
                .toList();

        try (OutputStream out = Files.newOutputStream(target);
             ZipOutputStream zip = new ZipOutputStream(out)) {

            zip.setMethod(ZipOutputStream.DEFLATED);

            for (Path arquivo : ordenados) {
                ZipEntry entrada = new ZipEntry(arquivo.getFileName().toString());
                entrada.setMethod(ZipEntry.DEFLATED);
                zip.putNextEntry(entrada);
                Files.copy(arquivo, zip);
                zip.closeEntry();
            }
        } catch (IOException ex) {
            throw new ProcessingException(ErrorCode.STORAGE_FAILURE,
                    "Falha ao criar o arquivo ZIP", ex);
        }
    }
}
```

`WorkerApplication.java`:
```java
package br.com.fiapx.worker;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class WorkerApplication {
    public static void main(String[] args) {
        SpringApplication.run(WorkerApplication.class, args);
    }
}
```

- [ ] **Step 6: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*ZipArchiveWriterTest'`
Expected: PASS — ZIP flat, deflate, entradas ordenadas.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: ports do worker e compactacao em ZIP flat

Mesmo formato do projeto base: sem diretorios internos, metodo deflate,
entradas ordenadas por nome para o zip ficar deterministico."
```

---

## Task 17: `processing-worker` — extração de frames com ffmpeg e timeout

**Files:**
- Create: `src/main/java/br/com/fiapx/worker/infrastructure/ffmpeg/FfmpegFrameExtractor.java`
- Create: `src/main/resources/application.yml`
- Create: `src/test/resources/fixtures/sample-2s.mp4` (gerado no Step 1)
- Test: `src/test/java/br/com/fiapx/worker/infrastructure/ffmpeg/FfmpegFrameExtractorTest.java`

**Interfaces:**
- Consumes: `FrameExtractor`, `ProcessingException` (Task 16).
- Produces: implementação de `FrameExtractor` que respeita `fiapx.ffmpeg.timeout-seconds`.

- [ ] **Step 1: Gerar o vídeo de teste e versioná-lo**

```bash
mkdir -p src/test/resources/fixtures
ffmpeg -f lavfi -i testsrc=duration=2:size=320x240:rate=30 \
       -pix_fmt yuv420p -y src/test/resources/fixtures/sample-2s.mp4
ls -la src/test/resources/fixtures/sample-2s.mp4
```
Expected: arquivo de ~15 KB. É commitado junto com o teste — o fixture precisa ser
o mesmo em qualquer máquina e no CI.

- [ ] **Step 2: Escrever o `application.yml`**

```yaml
spring:
  application:
    name: fiapx-processing-worker

server:
  port: 8083

fiapx:
  s3:
    bucket: ${S3_BUCKET:fiapx-videos}
  sqs:
    processing-queue: ${SQS_PROCESSING_QUEUE:video-processing-queue}
  sns:
    events-topic: ${SNS_EVENTS_TOPIC:video-events}
  ffmpeg:
    binary: ${FFMPEG_BINARY:ffmpeg}
    timeout-seconds: ${FFMPEG_TIMEOUT_SECONDS:600}
  work-dir: ${WORK_DIR:/tmp/fiapx}

spring.cloud.aws:
  region:
    static: ${AWS_REGION:us-east-1}
  endpoint: ${AWS_ENDPOINT:}
  s3:
    # true no LocalStack: sem isso o SDK monta "fiapx-videos.localstack:4566", host
    # que não resolve. Na AWS real fica false (virtual-hosted style).
    path-style-access-enabled: ${S3_PATH_STYLE:false}
  credentials:
    access-key: ${AWS_ACCESS_KEY_ID:test}
    secret-key: ${AWS_SECRET_ACCESS_KEY:test}
  sqs:
    listener:
      max-concurrent-messages: 2

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

- [ ] **Step 3: Escrever o teste do extrator (falha)**

```java
package br.com.fiapx.worker.infrastructure.ffmpeg;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.worker.application.exception.ProcessingException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class FfmpegFrameExtractorTest {

    private final FfmpegFrameExtractor extractor = new FfmpegFrameExtractor("ffmpeg", 600);

    private Path fixture(Path tmp) throws Exception {
        Path destino = tmp.resolve("sample-2s.mp4");
        try (var in = getClass().getResourceAsStream("/fixtures/sample-2s.mp4")) {
            Files.copy(in, destino);
        }
        return destino;
    }

    @Test
    void extraiUmFramePorSegundoEmPng(@TempDir Path tmp) throws Exception {
        Path saida = Files.createDirectory(tmp.resolve("frames"));

        List<Path> frames = extractor.extract(fixture(tmp), saida);

        assertThat(frames).hasSize(2);
        assertThat(frames.get(0).getFileName().toString()).isEqualTo("frame_0001.png");
        assertThat(frames.get(1).getFileName().toString()).isEqualTo("frame_0002.png");
        assertThat(Files.size(frames.get(0))).isPositive();
    }

    @Test
    void arquivoCorrompidoResultaEmFfmpegFailure(@TempDir Path tmp) throws Exception {
        Path quebrado = Files.writeString(tmp.resolve("quebrado.mp4"), "isto nao e um video");
        Path saida = Files.createDirectory(tmp.resolve("frames"));

        assertThatThrownBy(() -> extractor.extract(quebrado, saida))
                .isInstanceOf(ProcessingException.class)
                .satisfies(ex -> assertThat(((ProcessingException) ex).errorCode())
                        .isEqualTo(ErrorCode.FFMPEG_FAILURE));
    }

    @Test
    void timeoutZeroInterrompeOProcessoComTimeout(@TempDir Path tmp) throws Exception {
        var extractorImpaciente = new FfmpegFrameExtractor("ffmpeg", 0);
        Path saida = Files.createDirectory(tmp.resolve("frames"));

        assertThatThrownBy(() -> extractorImpaciente.extract(fixture(tmp), saida))
                .isInstanceOf(ProcessingException.class)
                .satisfies(ex -> assertThat(((ProcessingException) ex).errorCode())
                        .isEqualTo(ErrorCode.TIMEOUT));
    }

    @Test
    void binarioInexistenteResultaEmFfmpegFailure(@TempDir Path tmp) throws Exception {
        var extractorSemBinario = new FfmpegFrameExtractor("ffmpeg-que-nao-existe", 600);
        Path saida = Files.createDirectory(tmp.resolve("frames"));

        assertThatThrownBy(() -> extractorSemBinario.extract(fixture(tmp), saida))
                .isInstanceOf(ProcessingException.class);
    }
}
```

> Os testes exigem `ffmpeg` no PATH. É a mesma exigência do runtime, e o job de CI
> instala o binário antes de rodar o build (Task 21 da fase 2).

- [ ] **Step 4: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*FfmpegFrameExtractorTest'`
Expected: FAIL — `FfmpegFrameExtractor` não existe.

- [ ] **Step 5: Implementar o extrator**

```java
package br.com.fiapx.worker.infrastructure.ffmpeg;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.worker.application.exception.ProcessingException;
import br.com.fiapx.worker.application.port.out.FrameExtractor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.stream.Stream;

@Component
public class FfmpegFrameExtractor implements FrameExtractor {

    private static final Logger log = LoggerFactory.getLogger(FfmpegFrameExtractor.class);

    private final String binary;
    private final long timeoutSeconds;

    public FfmpegFrameExtractor(@Value("${fiapx.ffmpeg.binary}") String binary,
                                @Value("${fiapx.ffmpeg.timeout-seconds}") long timeoutSeconds) {
        this.binary = binary;
        this.timeoutSeconds = timeoutSeconds;
    }

    @Override
    public List<Path> extract(Path video, Path outputDir) {
        Path padrao = outputDir.resolve("frame_%04d.png");

        ProcessBuilder builder = new ProcessBuilder(
                binary, "-i", video.toAbsolutePath().toString(),
                "-vf", "fps=1", "-y", padrao.toAbsolutePath().toString());
        builder.redirectErrorStream(true);

        Process processo = null;
        try {
            processo = builder.start();

            if (!processo.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
                processo.destroyForcibly();
                throw new ProcessingException(ErrorCode.TIMEOUT,
                        "ffmpeg excedeu " + timeoutSeconds + "s");
            }

            String saida = new String(processo.getInputStream().readAllBytes(), StandardCharsets.UTF_8);

            if (processo.exitValue() != 0) {
                log.warn("ffmpeg falhou com codigo {}: {}", processo.exitValue(), saida);
                throw new ProcessingException(ErrorCode.FFMPEG_FAILURE,
                        "ffmpeg retornou codigo " + processo.exitValue());
            }

            List<Path> frames = listarFrames(outputDir);
            if (frames.isEmpty()) {
                throw new ProcessingException(ErrorCode.NO_FRAMES_EXTRACTED,
                        "Nenhum frame foi extraido do video");
            }
            log.info("Extraidos {} frames de {}", frames.size(), video.getFileName());
            return frames;

        } catch (IOException ex) {
            throw new ProcessingException(ErrorCode.FFMPEG_FAILURE,
                    "Falha ao executar o ffmpeg: " + ex.getMessage(), ex);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            if (processo != null) {
                processo.destroyForcibly();
            }
            throw new ProcessingException(ErrorCode.TIMEOUT, "Processamento interrompido", ex);
        }
    }

    private List<Path> listarFrames(Path outputDir) throws IOException {
        try (Stream<Path> arquivos = Files.list(outputDir)) {
            return arquivos
                    .filter(p -> p.getFileName().toString().endsWith(".png"))
                    .sorted(Comparator.comparing(p -> p.getFileName().toString()))
                    .toList();
        }
    }
}
```

- [ ] **Step 6: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*FfmpegFrameExtractorTest'`
Expected: PASS — 2 frames extraídos do vídeo de 2 s; erros mapeados para `FFMPEG_FAILURE` e `TIMEOUT`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: extracao de frames com ffmpeg, timeout e erros tipados

Diferente do projeto base, o processo tem timeout e e destruido a forca ao
estourar, e cada falha vira um ErrorCode que o usuario ve na listagem."
```

---

## Task 18: `processing-worker` — adapters de S3 e SNS

**Files:**
- Create: `src/main/java/br/com/fiapx/worker/infrastructure/config/AwsConfig.java`
- Create: `src/main/java/br/com/fiapx/worker/infrastructure/storage/S3VideoObjectStorage.java`
- Create: `src/main/java/br/com/fiapx/worker/infrastructure/messaging/SnsProcessingEventPublisher.java`
- Test: `src/test/java/br/com/fiapx/worker/support/LocalStackTestContainer.java`
- Test: `src/test/java/br/com/fiapx/worker/infrastructure/storage/S3VideoObjectStorageIT.java`
- Test: `src/test/java/br/com/fiapx/worker/infrastructure/messaging/SnsProcessingEventPublisherIT.java`

**Interfaces:**
- Consumes: `VideoObjectStorage`, `ProcessingEventPublisher`, `ProcessingException` (Task 16); `EventEnvelope`, payloads, `ContractsJson` (Task 2).
- Produces: implementações registradas como beans, usadas pelo `ProcessVideoUseCase` (Task 19).

- [ ] **Step 1: Escrever os testes de integração (falham)**

`support/LocalStackTestContainer.java` — idêntico ao do `video-api`, no pacote `br.com.fiapx.worker.support`.

`infrastructure/storage/S3VideoObjectStorageIT.java`:
```java
package br.com.fiapx.worker.infrastructure.storage;

import br.com.fiapx.worker.application.port.out.VideoObjectStorage;
import br.com.fiapx.worker.support.LocalStackTestContainer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@Import(LocalStackTestContainer.class)
class S3VideoObjectStorageIT {

    @Autowired VideoObjectStorage storage;
    @Autowired S3Client s3;

    @Value("${fiapx.s3.bucket}")
    String bucket;

    @BeforeEach
    void criarBucket() {
        try {
            s3.createBucket(b -> b.bucket(bucket));
        } catch (RuntimeException ignorado) {
            // bucket já existe entre testes
        }
    }

    @Test
    void baixaOObjetoParaOCaminhoInformado(@TempDir Path tmp) throws Exception {
        String key = "raw/" + UUID.randomUUID() + "/v.mp4";
        s3.putObject(b -> b.bucket(bucket).key(key), RequestBody.fromString("bytes-do-video"));
        Path destino = tmp.resolve("baixado.mp4");

        storage.download(key, destino);

        assertThat(Files.readString(destino)).isEqualTo("bytes-do-video");
    }

    @Test
    void enviaOZipParaAChaveProcessed(@TempDir Path tmp) throws Exception {
        UUID userId = UUID.randomUUID();
        UUID videoId = UUID.randomUUID();
        Path zip = Files.writeString(tmp.resolve("frames.zip"), "conteudo-zip");

        String key = storage.uploadZip(userId, videoId, zip);

        assertThat(key).isEqualTo("processed/" + userId + "/" + videoId + ".zip");
        assertThat(new String(s3.getObjectAsBytes(b -> b.bucket(bucket).key(key)).asByteArray(),
                StandardCharsets.UTF_8)).isEqualTo("conteudo-zip");
    }
}
```

`infrastructure/messaging/SnsProcessingEventPublisherIT.java`:
```java
package br.com.fiapx.worker.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.EventType;
import br.com.fiapx.contracts.VideoFailedPayload;
import br.com.fiapx.contracts.VideoProcessedPayload;
import br.com.fiapx.worker.application.port.out.ProcessingEventPublisher;
import br.com.fiapx.worker.support.LocalStackTestContainer;
import com.fasterxml.jackson.core.type.TypeReference;
import io.awspring.cloud.sqs.operations.SqsTemplate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;

import java.time.Duration;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@Import(LocalStackTestContainer.class)
class SnsProcessingEventPublisherIT {

    @Autowired ProcessingEventPublisher publisher;
    @Autowired SnsClient sns;
    @Autowired SqsAsyncClient sqs; // o spring-cloud-aws só autoconfigura o cliente assíncrono
    @Autowired SqsTemplate sqsTemplate;

    @Value("${fiapx.sns.events-topic}")
    String topico;

    private String filaDeProva;

    @BeforeEach
    void assinarFilaDeProva() {
        String topicArn = sns.createTopic(b -> b.name(topico)).topicArn();
        filaDeProva = "prova-" + UUID.randomUUID();
        String queueUrl = sqs.createQueue(b -> b.queueName(filaDeProva)).join().queueUrl();
        String queueArn = sqs.getQueueAttributes(b -> b.queueUrl(queueUrl)
                .attributeNamesWithStrings("QueueArn")).join().attributesAsStrings().get("QueueArn");

        sns.subscribe(b -> b.topicArn(topicArn).protocol("sqs").endpoint(queueArn)
                .attributes(Map.of("RawMessageDelivery", "true")));
    }

    private String receber() {
        return sqsTemplate.receive(from -> from.queue(filaDeProva)
                        .pollTimeout(Duration.ofSeconds(10)), String.class)
                .orElseThrow()
                .getPayload();
    }

    @Test
    void publicaVideoProcessed() throws Exception {
        UUID videoId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();

        publisher.publishProcessed(videoId, userId, "processed/u/v.zip", 42, 1500L);

        var envelope = ContractsJson.mapper().readValue(receber(),
                new TypeReference<EventEnvelope<VideoProcessedPayload>>() {});

        assertThat(envelope.eventType()).isEqualTo(EventType.VIDEO_PROCESSED);
        assertThat(envelope.correlationId()).isEqualTo(videoId);
        assertThat(envelope.payload().frameCount()).isEqualTo(42);
        assertThat(envelope.payload().s3ZipKey()).isEqualTo("processed/u/v.zip");
    }

    @Test
    void publicaVideoFailedComCodigoEEmailDoUsuario() throws Exception {
        UUID videoId = UUID.randomUUID();

        publisher.publishFailed(videoId, UUID.randomUUID(), "aluno@fiap.com.br",
                ErrorCode.FFMPEG_FAILURE, "codec invalido", 2);

        var envelope = ContractsJson.mapper().readValue(receber(),
                new TypeReference<EventEnvelope<VideoFailedPayload>>() {});

        assertThat(envelope.eventType()).isEqualTo(EventType.VIDEO_FAILED);
        assertThat(envelope.payload().errorCode()).isEqualTo(ErrorCode.FFMPEG_FAILURE);
        assertThat(envelope.payload().userEmail()).isEqualTo("aluno@fiap.com.br");
        assertThat(envelope.payload().attempt()).isEqualTo(2);
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falham**

Run: `./mvnw test -Dtest='*IT'`
Expected: FAIL — nenhum dos dois adapters existe.

- [ ] **Step 3: Implementar `AwsConfig` e o adapter de S3**

`infrastructure/config/AwsConfig.java`:
```java
package br.com.fiapx.worker.infrastructure.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

@Configuration
public class AwsConfig {

    /** Diretório base de trabalho, criado na subida para falhar cedo se não houver permissão. */
    @Bean
    Path workDir(@Value("${fiapx.work-dir}") String workDir) throws IOException {
        return Files.createDirectories(Path.of(workDir));
    }
}
```

`infrastructure/storage/S3VideoObjectStorage.java`:
```java
package br.com.fiapx.worker.infrastructure.storage;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.worker.application.exception.ProcessingException;
import br.com.fiapx.worker.application.port.out.VideoObjectStorage;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;

import java.nio.file.Path;
import java.util.UUID;

@Component
class S3VideoObjectStorage implements VideoObjectStorage {

    private final S3Client s3;
    private final String bucket;

    S3VideoObjectStorage(S3Client s3, @Value("${fiapx.s3.bucket}") String bucket) {
        this.s3 = s3;
        this.bucket = bucket;
    }

    @Override
    public void download(String key, Path target) {
        try {
            s3.getObject(GetObjectRequest.builder().bucket(bucket).key(key).build(), target);
        } catch (RuntimeException ex) {
            throw new ProcessingException(ErrorCode.STORAGE_FAILURE,
                    "Falha ao baixar o objeto " + key, ex);
        }
    }

    @Override
    public String uploadZip(UUID userId, UUID videoId, Path zip) {
        String key = "processed/%s/%s.zip".formatted(userId, videoId);
        try {
            s3.putObject(PutObjectRequest.builder()
                    .bucket(bucket)
                    .key(key)
                    .contentType("application/zip")
                    .build(), RequestBody.fromFile(zip));
            return key;
        } catch (RuntimeException ex) {
            throw new ProcessingException(ErrorCode.STORAGE_FAILURE,
                    "Falha ao enviar o ZIP " + key, ex);
        }
    }
}
```

- [ ] **Step 4: Implementar o publisher de SNS**

```java
package br.com.fiapx.worker.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.EventType;
import br.com.fiapx.contracts.VideoFailedPayload;
import br.com.fiapx.contracts.VideoProcessedPayload;
import br.com.fiapx.contracts.VideoProcessingStartedPayload;
import br.com.fiapx.worker.application.port.out.ProcessingEventPublisher;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.awspring.cloud.sns.core.SnsTemplate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.UUID;

@Component
class SnsProcessingEventPublisher implements ProcessingEventPublisher {

    private static final Logger log = LoggerFactory.getLogger(SnsProcessingEventPublisher.class);

    private final SnsTemplate snsTemplate;
    private final ObjectMapper mapper = ContractsJson.mapper();
    private final String topic;

    SnsProcessingEventPublisher(SnsTemplate snsTemplate,
                                @Value("${fiapx.sns.events-topic}") String topic) {
        this.snsTemplate = snsTemplate;
        this.topic = topic;
    }

    @Override
    public void publishStarted(UUID videoId, UUID userId, int attempt) {
        publish(EventType.VIDEO_PROCESSING_STARTED, videoId,
                new VideoProcessingStartedPayload(videoId, userId, hostname(), attempt));
    }

    @Override
    public void publishProcessed(UUID videoId, UUID userId, String s3ZipKey,
                                 int frameCount, long millis) {
        publish(EventType.VIDEO_PROCESSED, videoId,
                new VideoProcessedPayload(videoId, userId, s3ZipKey, frameCount, millis));
    }

    @Override
    public void publishFailed(UUID videoId, UUID userId, String userEmail,
                              ErrorCode errorCode, String errorMessage, int attempt) {
        publish(EventType.VIDEO_FAILED, videoId,
                new VideoFailedPayload(videoId, userId, userEmail, errorCode, errorMessage, attempt));
    }

    private void publish(EventType tipo, UUID videoId, Object payload) {
        var envelope = EventEnvelope.of(tipo, videoId, payload);
        try {
            snsTemplate.sendNotification(topic, mapper.writeValueAsString(envelope), null);
            log.info("Evento {} publicado correlationId={}", tipo.wireName(), videoId);
        } catch (Exception ex) {
            throw new IllegalStateException(
                    "Falha ao publicar " + tipo.wireName() + " para " + videoId, ex);
        }
    }

    private static String hostname() {
        try {
            return java.net.InetAddress.getLocalHost().getHostName();
        } catch (Exception ex) {
            return "desconhecido";
        }
    }
}
```

- [ ] **Step 5: Rodar e confirmar que passam**

Run: `./mvnw test -Dtest='*IT'`
Expected: PASS — download e upload no bucket, e os dois eventos chegando à fila assinada no tópico.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: adapters de S3 e SNS do worker

Falha de storage vira ProcessingException com STORAGE_FAILURE, para que o
usuario receba um motivo util em vez de um erro generico."
```

---

## Task 19: `processing-worker` — orquestração do processamento

O caso de uso que junta tudo. Toda falha vira um `VideoFailedEvent`; nenhum diretório temporário sobrevive à execução.

**Files:**
- Create: `src/main/java/br/com/fiapx/worker/application/usecase/ProcessVideoUseCase.java`
- Test: `src/test/java/br/com/fiapx/worker/application/usecase/ProcessVideoUseCaseTest.java`

**Interfaces:**
- Consumes: os quatro ports (Task 16); `VideoUploadedPayload`, `ErrorCode` (Task 2).
- Produces: `ProcessVideoUseCase.execute(VideoUploadedPayload payload, int attempt)` → `void`

- [ ] **Step 1: Escrever o teste (falha)**

```java
package br.com.fiapx.worker.application.usecase;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.contracts.VideoUploadedPayload;
import br.com.fiapx.worker.application.exception.ProcessingException;
import br.com.fiapx.worker.application.port.out.ArchiveWriter;
import br.com.fiapx.worker.application.port.out.FrameExtractor;
import br.com.fiapx.worker.application.port.out.ProcessingEventPublisher;
import br.com.fiapx.worker.application.port.out.VideoObjectStorage;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.mockito.InOrder;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProcessVideoUseCaseTest {

    private VideoObjectStorage storage;
    private FrameExtractor extractor;
    private ArchiveWriter archiveWriter;
    private ProcessingEventPublisher publisher;
    private ProcessVideoUseCase useCase;

    private final UUID videoId = UUID.randomUUID();
    private final UUID userId = UUID.randomUUID();
    private Path baseDir;

    private VideoUploadedPayload payload() {
        return new VideoUploadedPayload(videoId, userId, "aluno@fiap.com.br",
                "raw/u/v.mp4", "clipe.mp4", 2048L);
    }

    @BeforeEach
    void setUp(@TempDir Path tmp) {
        baseDir = tmp;
        storage = mock(VideoObjectStorage.class);
        extractor = mock(FrameExtractor.class);
        archiveWriter = mock(ArchiveWriter.class);
        publisher = mock(ProcessingEventPublisher.class);
        useCase = new ProcessVideoUseCase(storage, extractor, archiveWriter, publisher, tmp);

        when(extractor.extract(any(), any())).thenAnswer(invocacao -> {
            Path saida = invocacao.getArgument(1);
            return List.of(
                    Files.writeString(saida.resolve("frame_0001.png"), "a"),
                    Files.writeString(saida.resolve("frame_0002.png"), "b"));
        });
        when(storage.uploadZip(eq(userId), eq(videoId), any())).thenReturn("processed/u/v.zip");
    }

    @Test
    void caminhoFelizPublicaStartedEProcessedNaOrdem() {
        useCase.execute(payload(), 1);

        InOrder ordem = inOrder(publisher, storage, extractor, archiveWriter);
        ordem.verify(publisher).publishStarted(videoId, userId, 1);
        ordem.verify(storage).download(eq("raw/u/v.mp4"), any());
        ordem.verify(extractor).extract(any(), any());
        ordem.verify(archiveWriter).write(any(), any());
        ordem.verify(storage).uploadZip(eq(userId), eq(videoId), any());
        ordem.verify(publisher).publishProcessed(eq(videoId), eq(userId),
                eq("processed/u/v.zip"), eq(2), anyLong());
    }

    @Test
    void falhaDoFfmpegViraVideoFailedComOMesmoErrorCode() {
        when(extractor.extract(any(), any()))
                .thenThrow(new ProcessingException(ErrorCode.FFMPEG_FAILURE, "codec invalido"));

        useCase.execute(payload(), 2);

        verify(publisher).publishFailed(videoId, userId, "aluno@fiap.com.br",
                ErrorCode.FFMPEG_FAILURE, "codec invalido", 2);
        verify(publisher, never()).publishProcessed(any(), any(), anyString(), anyInt(), anyLong());
    }

    @Test
    void erroInesperadoViraUnknownEmVezDeVazarExcecao() {
        doThrow(new IllegalStateException("boom")).when(storage).download(anyString(), any());

        useCase.execute(payload(), 1);

        verify(publisher).publishFailed(eq(videoId), eq(userId), eq("aluno@fiap.com.br"),
                eq(ErrorCode.UNKNOWN), anyString(), eq(1));
    }

    @Test
    void removeODiretorioTemporarioMesmoEmCasoDeFalha() throws Exception {
        when(extractor.extract(any(), any()))
                .thenThrow(new ProcessingException(ErrorCode.TIMEOUT, "estourou"));

        useCase.execute(payload(), 1);

        try (var conteudo = Files.list(baseDir)) {
            assertThat(conteudo).isEmpty();
        }
    }

    @Test
    void removeODiretorioTemporarioNoCaminhoFeliz() throws Exception {
        useCase.execute(payload(), 1);

        try (var conteudo = Files.list(baseDir)) {
            assertThat(conteudo).isEmpty();
        }
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*ProcessVideoUseCaseTest'`
Expected: FAIL — `ProcessVideoUseCase` não existe.

- [ ] **Step 3: Implementar o use case**

```java
package br.com.fiapx.worker.application.usecase;

import br.com.fiapx.contracts.ErrorCode;
import br.com.fiapx.contracts.VideoUploadedPayload;
import br.com.fiapx.worker.application.exception.ProcessingException;
import br.com.fiapx.worker.application.port.out.ArchiveWriter;
import br.com.fiapx.worker.application.port.out.FrameExtractor;
import br.com.fiapx.worker.application.port.out.ProcessingEventPublisher;
import br.com.fiapx.worker.application.port.out.VideoObjectStorage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Stream;

@Service
public class ProcessVideoUseCase {

    private static final Logger log = LoggerFactory.getLogger(ProcessVideoUseCase.class);

    private final VideoObjectStorage storage;
    private final FrameExtractor extractor;
    private final ArchiveWriter archiveWriter;
    private final ProcessingEventPublisher publisher;
    private final Path workDir;

    public ProcessVideoUseCase(VideoObjectStorage storage, FrameExtractor extractor,
                               ArchiveWriter archiveWriter, ProcessingEventPublisher publisher,
                               Path workDir) {
        this.storage = storage;
        this.extractor = extractor;
        this.archiveWriter = archiveWriter;
        this.publisher = publisher;
        this.workDir = workDir;
    }

    /**
     * Nunca propaga exceção: toda falha vira um VideoFailedEvent. Deixar a exceção
     * escapar faria o SQS devolver a mensagem à fila e reprocessar um vídeo que já
     * se sabe defeituoso.
     */
    public void execute(VideoUploadedPayload payload, int attempt) {
        long inicio = System.currentTimeMillis();
        Path diretorio = null;

        try {
            publisher.publishStarted(payload.videoId(), payload.userId(), attempt);

            diretorio = Files.createTempDirectory(workDir, "video-" + payload.videoId() + "-");
            Path video = diretorio.resolve("entrada" + extensaoDe(payload.originalFilename()));
            Path frames = Files.createDirectory(diretorio.resolve("frames"));
            Path zip = diretorio.resolve("frames.zip");

            storage.download(payload.s3RawKey(), video);
            List<Path> extraidos = extractor.extract(video, frames);
            archiveWriter.write(extraidos, zip);
            String zipKey = storage.uploadZip(payload.userId(), payload.videoId(), zip);

            long duracao = System.currentTimeMillis() - inicio;
            publisher.publishProcessed(payload.videoId(), payload.userId(),
                    zipKey, extraidos.size(), duracao);
            log.info("Video {} processado: {} frames em {} ms",
                    payload.videoId(), extraidos.size(), duracao);

        } catch (ProcessingException ex) {
            log.warn("Falha ao processar {}: {}", payload.videoId(), ex.getMessage());
            publisher.publishFailed(payload.videoId(), payload.userId(), payload.userEmail(),
                    ex.errorCode(), ex.getMessage(), attempt);

        } catch (Exception ex) {
            log.error("Falha inesperada ao processar {}", payload.videoId(), ex);
            publisher.publishFailed(payload.videoId(), payload.userId(), payload.userEmail(),
                    ErrorCode.UNKNOWN, String.valueOf(ex.getMessage()), attempt);

        } finally {
            apagar(diretorio);
        }
    }

    private static String extensaoDe(String filename) {
        int ponto = filename.lastIndexOf('.');
        return ponto < 0 ? "" : filename.substring(ponto);
    }

    private void apagar(Path diretorio) {
        if (diretorio == null || !Files.exists(diretorio)) {
            return;
        }
        try (Stream<Path> caminhos = Files.walk(diretorio)) {
            caminhos.sorted(Comparator.reverseOrder()).forEach(caminho -> {
                try {
                    Files.deleteIfExists(caminho);
                } catch (IOException ex) {
                    log.warn("Nao foi possivel apagar {}", caminho, ex);
                }
            });
        } catch (IOException ex) {
            log.warn("Falha ao limpar o diretorio temporario {}", diretorio, ex);
        }
    }
}
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `./mvnw test -Dtest='*ProcessVideoUseCaseTest'`
Expected: PASS — 5 testes verdes, inclusive os dois que verificam que o diretório temporário sumiu.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: orquestracao do processamento de video

O use case nunca propaga excecao: toda falha vira VideoFailed com um
ErrorCode. O diretorio temporario e removido em finally, no sucesso e na
falha, para o pod nao encher o disco efemero."
```

---

## Task 20: `processing-worker` — listener SQS, imagem com ffmpeg e README

**Files:**
- Create: `src/main/java/br/com/fiapx/worker/infrastructure/messaging/VideoProcessingListener.java`
- Create: `services/fiapx-processing-worker/{Dockerfile,.dockerignore,README.md}`
- Test: `src/test/java/br/com/fiapx/worker/infrastructure/messaging/VideoProcessingListenerIT.java`

**Interfaces:**
- Consumes: `ProcessVideoUseCase` (Task 19); `EventEnvelope`, `VideoUploadedPayload`, `ContractsJson` (Task 2).
- Produces: imagem `fiapx/processing-worker:local`, usada na Task 21.

- [ ] **Step 1: Escrever o teste de integração (falha)**

```java
package br.com.fiapx.worker.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.EventType;
import br.com.fiapx.contracts.VideoUploadedPayload;
import br.com.fiapx.worker.support.LocalStackTestContainer;
import io.awspring.cloud.sqs.operations.SqsTemplate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;

import java.io.InputStream;
import java.time.Duration;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

@SpringBootTest
@Import(LocalStackTestContainer.class)
class VideoProcessingListenerIT {

    @Autowired SqsTemplate sqsTemplate;
    @Autowired SqsAsyncClient sqs; // o spring-cloud-aws só autoconfigura o cliente assíncrono
    @Autowired SnsClient sns;
    @Autowired S3Client s3;

    @Value("${fiapx.sqs.processing-queue}") String fila;
    @Value("${fiapx.sns.events-topic}") String topico;
    @Value("${fiapx.s3.bucket}") String bucket;

    @BeforeEach
    void prepararRecursos() {
        try {
            s3.createBucket(b -> b.bucket(bucket));
        } catch (RuntimeException ignorado) {
            // já existe
        }
        sqs.createQueue(b -> b.queueName(fila)).join();
        sns.createTopic(b -> b.name(topico));
    }

    @Test
    void consomeVideoUploadedEGravaOZipNoS3() throws Exception {
        UUID videoId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        String rawKey = "raw/" + userId + "/" + videoId + ".mp4";

        try (InputStream fixture = getClass().getResourceAsStream("/fixtures/sample-2s.mp4")) {
            byte[] bytes = fixture.readAllBytes();
            s3.putObject(b -> b.bucket(bucket).key(rawKey), RequestBody.fromBytes(bytes));
        }

        var envelope = EventEnvelope.of(EventType.VIDEO_UPLOADED, videoId,
                new VideoUploadedPayload(videoId, userId, "aluno@fiap.com.br",
                        rawKey, "sample-2s.mp4", 15_000L));

        // Serializa fora do lambda: a JsonProcessingException é checada e o Consumer não a propaga.
        String json = ContractsJson.mapper().writeValueAsString(envelope);
        sqsTemplate.send(to -> to.queue(fila).payload(json));

        String zipKey = "processed/" + userId + "/" + videoId + ".zip";
        await().atMost(Duration.ofSeconds(60)).untilAsserted(() ->
                assertThat(s3.getObjectAsBytes(b -> b.bucket(bucket).key(zipKey)).asByteArray())
                        .isNotEmpty());
    }
}
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `./mvnw test -Dtest='*VideoProcessingListenerIT'`
Expected: FAIL — o listener não existe, o ZIP nunca aparece no bucket.

- [ ] **Step 3: Implementar o listener**

```java
package br.com.fiapx.worker.infrastructure.messaging;

import br.com.fiapx.contracts.ContractsJson;
import br.com.fiapx.contracts.EventEnvelope;
import br.com.fiapx.contracts.VideoUploadedPayload;
import br.com.fiapx.worker.application.usecase.ProcessVideoUseCase;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.awspring.cloud.sqs.annotation.SqsListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.stereotype.Component;

@Component
class VideoProcessingListener {

    private static final Logger log = LoggerFactory.getLogger(VideoProcessingListener.class);

    private final ProcessVideoUseCase useCase;
    private final ObjectMapper mapper = ContractsJson.mapper();

    VideoProcessingListener(ProcessVideoUseCase useCase) {
        this.useCase = useCase;
    }

    @SqsListener("${fiapx.sqs.processing-queue}")
    void onMessage(String body,
                   @Header(name = "ApproximateReceiveCount", required = false) String receiveCount) {
        try {
            EventEnvelope<VideoUploadedPayload> envelope =
                    mapper.readValue(body, new TypeReference<>() {});

            int tentativa = receiveCount == null ? 1 : Integer.parseInt(receiveCount);
            useCase.execute(envelope.payload(), tentativa);

        } catch (Exception ex) {
            // Mensagem ilegível: registrar e descartar. Devolver à fila só a faria
            // circular até cair na DLQ sem nunca ser processável.
            log.error("Mensagem descartada por payload invalido: {}", body, ex);
        }
    }
}
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `./mvnw verify`
Expected: PASS — o ZIP aparece no bucket em `processed/{userId}/{videoId}.zip`.

- [ ] **Step 5: Escrever o `Dockerfile` com ffmpeg**

```dockerfile
# syntax=docker/dockerfile:1
# Contexto de build: services/
#   docker build -f fiapx-processing-worker/Dockerfile -t fiapx/processing-worker:local ..
FROM maven:3.9-eclipse-temurin-21-alpine AS build
WORKDIR /workspace

COPY fiapx-contracts/pom.xml /workspace/fiapx-contracts/pom.xml
COPY fiapx-contracts/src /workspace/fiapx-contracts/src
RUN mvn -B -q -f /workspace/fiapx-contracts/pom.xml install -DskipTests

COPY fiapx-processing-worker/pom.xml /workspace/app/
WORKDIR /workspace/app
RUN mvn -B -q dependency:go-offline || true
COPY fiapx-processing-worker/src /workspace/app/src
RUN mvn -B -q package -DskipTests

FROM eclipse-temurin:21-jre-alpine
RUN apk add --no-cache ffmpeg \
 && addgroup -S fiapx && adduser -S fiapx -G fiapx \
 && mkdir -p /tmp/fiapx && chown fiapx:fiapx /tmp/fiapx
WORKDIR /app
COPY --from=build /workspace/app/target/*.jar app.jar
USER fiapx
EXPOSE 8083
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75"
HEALTHCHECK --interval=10s --timeout=3s --start-period=60s --retries=6 \
  CMD wget -qO- http://localhost:8083/actuator/health/readiness | grep -q UP || exit 1
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

`.dockerignore`:
```
.git
target
*.md
```

- [ ] **Step 6: Construir a imagem e conferir o ffmpeg**

```bash
cd services
docker build -f fiapx-processing-worker/Dockerfile -t fiapx/processing-worker:local .
docker run --rm --entrypoint ffmpeg fiapx/processing-worker:local -version | head -1
```
Expected: a versão do ffmpeg é impressa.

- [ ] **Step 7: Escrever o `README.md`**

```markdown
# fiapx-processing-worker

Consome `video-processing-queue`, extrai 1 frame por segundo com ffmpeg, compacta
em ZIP e publica o resultado no tópico SNS `video-events`. Não expõe API — apenas
`/actuator` na porta 8083.

É este serviço que escala horizontalmente: N réplicas consomem a mesma fila.

## Rodar os testes

    ./mvnw verify

Requer Docker (LocalStack) e `ffmpeg` no PATH.

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `S3_BUCKET` | `fiapx-videos` | Bucket |
| `SQS_PROCESSING_QUEUE` | `video-processing-queue` | Fila de entrada |
| `SNS_EVENTS_TOPIC` | `video-events` | Tópico de saída |
| `FFMPEG_TIMEOUT_SECONDS` | `600` | Timeout do processo |
| `WORK_DIR` | `/tmp/fiapx` | Diretório temporário |
| `AWS_ENDPOINT` | vazio | Aponte para o LocalStack no ambiente local |
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: listener SQS e imagem do worker com ffmpeg

A tentativa vem do header ApproximateReceiveCount, o que permite o
VideoFailed informar em qual tentativa a falha ocorreu."
```

---

## Task 21: `fiapx-infra` — ambiente local completo e script de banco

**Files (todos no repositório `fiapx-infra`, a raiz do projeto):**
- Create: `sql/schema.sql`
- Create: `sql/init/01-create-databases.sh`
- Create: `localstack/init/01-resources.sh`
- Create: `docker-compose.yml`
- Create: `.env.example`

**Interfaces:**
- Consumes: as três imagens (`fiapx/auth-service:local`, `fiapx/video-api:local`, `fiapx/processing-worker:local`).
- Produces: ambiente acessível em `http://localhost:8081` e `http://localhost:8082`, usado pelos testes E2E da Task 22.

- [ ] **Step 1: Escrever `sql/schema.sql` (entregável do PDF)**

```sql
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
```

> Cada bloco acima roda no seu proprio banco (`auth_db`, `video_db`,
> `notification_db`) — nao ha schema compartilhado nem chave estrangeira cruzando
> servicos.

- [ ] **Step 2: Escrever `sql/init/01-create-databases.sh`**

```bash
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE auth_db;
    CREATE DATABASE video_db;
    CREATE DATABASE notification_db;
EOSQL
echo "Bancos auth_db, video_db e notification_db criados."
```

- [ ] **Step 3: Escrever `localstack/init/01-resources.sh`**

```bash
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

for QUEUE in "${STATUS_QUEUE}" "${NOTIFICATION_QUEUE}"; do
    QUEUE_URL=$(awslocal sqs create-queue --queue-name "${QUEUE}" --output text --query QueueUrl)
    QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url "${QUEUE_URL}" \
        --attribute-names QueueArn --output text --query 'Attributes.QueueArn')
    awslocal sns subscribe --topic-arn "${TOPIC_ARN}" --protocol sqs \
        --notification-endpoint "${QUEUE_ARN}" \
        --attributes RawMessageDelivery=true
done

echo "Recursos criados: bucket ${BUCKET}, filas e topico ${TOPIC}."
```

> `RawMessageDelivery=true` faz o SQS receber o JSON do evento diretamente, sem o
> envelope do SNS. O listener da Task 14 trata os dois formatos, mas o modo raw
> mantém as mensagens legíveis na inspeção manual.

- [ ] **Step 4: Escrever o `docker-compose.yml`**

```yaml
name: fiapx

services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: fiapx
      POSTGRES_PASSWORD: fiapx
      POSTGRES_DB: postgres
    ports: ["5432:5432"]
    volumes:
      - ./sql/init:/docker-entrypoint-initdb.d:ro
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U fiapx"]
      interval: 5s
      timeout: 3s
      retries: 10

  localstack:
    image: localstack/localstack:3.8
    environment:
      SERVICES: s3,sqs,sns
      DEBUG: 0
    ports: ["4566:4566"]
    volumes:
      - ./localstack/init:/etc/localstack/init/ready.d:ro
    healthcheck:
      test: ["CMD-SHELL", "awslocal sqs list-queues && awslocal s3 ls"]
      interval: 5s
      timeout: 5s
      retries: 20

  auth-service:
    build:
      context: ./services/fiapx-auth-service
    image: fiapx/auth-service:local
    depends_on:
      postgres: { condition: service_healthy }
    environment:
      DB_URL: jdbc:postgresql://postgres:5432/auth_db
      DB_USER: fiapx
      DB_PASSWORD: fiapx
    ports: ["8081:8081"]

  video-api:
    build:
      context: ./services
      dockerfile: fiapx-video-api/Dockerfile
    image: fiapx/video-api:local
    depends_on:
      postgres: { condition: service_healthy }
      localstack: { condition: service_healthy }
      auth-service: { condition: service_healthy }
    environment:
      DB_URL: jdbc:postgresql://postgres:5432/video_db
      DB_USER: fiapx
      DB_PASSWORD: fiapx
      JWKS_URI: http://auth-service:8081/.well-known/jwks.json
      AWS_ENDPOINT: http://localstack:4566
      AWS_REGION: us-east-1
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      S3_BUCKET: fiapx-videos
      S3_PUBLIC_ENDPOINT: http://localhost:4566   # host da URL assinada, alcançável pelo navegador
      S3_PATH_STYLE: "true"
      SQS_PROCESSING_QUEUE: video-processing-queue
      SQS_STATUS_QUEUE: video-status-queue
    ports: ["8082:8082"]

  processing-worker:
    build:
      context: ./services
      dockerfile: fiapx-processing-worker/Dockerfile
    image: fiapx/processing-worker:local
    depends_on:
      localstack: { condition: service_healthy }
    environment:
      AWS_ENDPOINT: http://localstack:4566
      AWS_REGION: us-east-1
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      S3_BUCKET: fiapx-videos
      S3_PATH_STYLE: "true"
      SQS_PROCESSING_QUEUE: video-processing-queue
      SNS_EVENTS_TOPIC: video-events
      WORK_DIR: /tmp/fiapx
    deploy:
      replicas: 2

volumes:
  pgdata:
```

`.env.example`:
```
# O ambiente local não usa credenciais reais da AWS; o LocalStack aceita "test".
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_REGION=us-east-1
```

- [ ] **Step 5: Subir e verificar manualmente**

```bash
docker compose up --build -d
docker compose ps
curl -s -X POST http://localhost:8081/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"aluno@fiap.com.br","password":"fiapx2026","fullName":"Aluno FIAP"}'
TOKEN=$(curl -s -X POST http://localhost:8081/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"aluno@fiap.com.br","password":"fiapx2026"}' | jq -r .accessToken)
curl -s -X POST http://localhost:8082/api/v1/videos \
  -H "Authorization: Bearer $TOKEN" \
  -F "video=@services/fiapx-processing-worker/src/test/resources/fixtures/sample-2s.mp4"
sleep 15
curl -s http://localhost:8082/api/v1/videos -H "Authorization: Bearer $TOKEN" | jq
```
Expected: cadastro `201`, login com token, upload `202`, e a listagem mostrando
`"status": "COMPLETED"` com `frameCount: 2`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: ambiente local completo com Compose e LocalStack

Sobe Postgres com os tres bancos, LocalStack provisionando bucket, filas
com DLQ e topico, e dois workers. Sem nenhuma credencial AWS real."
```

---

## Task 22: `fiapx-infra` — teste de ponta a ponta

Prova de que a fatia vertical funciona, e a rede de segurança que mantém o Compose vivo enquanto a fase 2 avança.

**Files:**
- Create: `e2e/pom.xml`
- Create: `e2e/src/test/java/br/com/fiapx/e2e/VideoProcessingE2ETest.java`
- Create: `e2e/src/test/resources/fixtures/sample-2s.mp4` (cópia do fixture do worker)
- Modify: `README.md`

**Interfaces:**
- Consumes: o ambiente da Task 21 (`http://localhost:8081` e `http://localhost:8082`).
- Produces: `./mvnw test` em `e2e/` como critério de aceitação da fase 1.

- [ ] **Step 1: Escrever o `pom.xml` do módulo e2e e copiar o Maven wrapper**

```bash
mkdir -p e2e
cp -r services/fiapx-contracts/mvnw services/fiapx-contracts/mvnw.cmd services/fiapx-contracts/.mvn e2e/
```

`e2e/pom.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <groupId>br.com.fiapx</groupId>
    <artifactId>fiapx-e2e</artifactId>
    <version>1.0.0</version>

    <properties>
        <maven.compiler.release>21</maven.compiler.release>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
        <!-- Sobrescreva com -Dauth.url=... e -Dvideo.url=... para apontar para outro ambiente -->
        <auth.url>http://localhost:8081</auth.url>
        <video.url>http://localhost:8082</video.url>
    </properties>

    <dependencyManagement>
        <dependencies>
            <dependency>
                <groupId>org.junit</groupId>
                <artifactId>junit-bom</artifactId>
                <version>5.10.3</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
        </dependencies>
    </dependencyManagement>

    <dependencies>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.rest-assured</groupId>
            <artifactId>rest-assured</artifactId>
            <version>5.5.0</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <version>3.26.3</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.awaitility</groupId>
            <artifactId>awaitility</artifactId>
            <version>4.2.2</version>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-compiler-plugin</artifactId>
                <version>3.13.0</version>
            </plugin>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-surefire-plugin</artifactId>
                <version>3.5.2</version>
                <configuration>
                    <systemPropertyVariables>
                        <auth.url>${auth.url}</auth.url>
                        <video.url>${video.url}</video.url>
                    </systemPropertyVariables>
                </configuration>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Copiar o fixture**

```bash
mkdir -p e2e/src/test/resources/fixtures
cp services/fiapx-processing-worker/src/test/resources/fixtures/sample-2s.mp4 \
   e2e/src/test/resources/fixtures/
```

- [ ] **Step 3: Escrever o teste E2E**

```java
package br.com.fiapx.e2e;

import io.restassured.RestAssured;
import io.restassured.http.ContentType;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.io.File;
import java.io.InputStream;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.UUID;
import java.util.zip.ZipInputStream;

import static io.restassured.RestAssured.given;
import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

class VideoProcessingE2ETest {

    private static String authUrl;
    private static String videoUrl;
    private static File fixture;

    @BeforeAll
    static void setUp() throws Exception {
        authUrl = System.getProperty("auth.url", "http://localhost:8081");
        videoUrl = System.getProperty("video.url", "http://localhost:8082");
        RestAssured.enableLoggingOfRequestAndResponseIfValidationFails();

        Path destino = Files.createTempFile("sample", ".mp4");
        try (InputStream in = VideoProcessingE2ETest.class
                .getResourceAsStream("/fixtures/sample-2s.mp4")) {
            Files.copy(in, destino, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        }
        fixture = destino.toFile();
    }

    private String registrarELogar(String email) {
        given().baseUri(authUrl).contentType(ContentType.JSON)
                .body("""
                        {"email":"%s","password":"fiapx2026","fullName":"Aluno E2E"}
                        """.formatted(email))
                .post("/api/v1/auth/register")
                .then().statusCode(201);

        return given().baseUri(authUrl).contentType(ContentType.JSON)
                .body("""
                        {"email":"%s","password":"fiapx2026"}
                        """.formatted(email))
                .post("/api/v1/auth/login")
                .then().statusCode(200)
                .extract().path("accessToken");
    }

    private String enviarVideo(String token) {
        return given().baseUri(videoUrl).header("Authorization", "Bearer " + token)
                .multiPart("video", fixture)
                .post("/api/v1/videos")
                .then().statusCode(202)
                .body("status", org.hamcrest.Matchers.equalTo("PENDING"))
                .extract().path("id");
    }

    private void aguardarConclusao(String token, String videoId) {
        await().atMost(Duration.ofMinutes(2)).pollInterval(Duration.ofSeconds(2))
                .untilAsserted(() ->
                        given().baseUri(videoUrl).header("Authorization", "Bearer " + token)
                                .get("/api/v1/videos/" + videoId)
                                .then().statusCode(200)
                                .body("status", org.hamcrest.Matchers.equalTo("COMPLETED")));
    }

    @Test
    void fluxoCompletoDoUploadAoDownloadDoZip() throws Exception {
        String token = registrarELogar("e2e-" + UUID.randomUUID() + "@fiap.com.br");
        String videoId = enviarVideo(token);

        aguardarConclusao(token, videoId);

        given().baseUri(videoUrl).header("Authorization", "Bearer " + token)
                .get("/api/v1/videos/" + videoId)
                .then().statusCode(200)
                .body("frameCount", org.hamcrest.Matchers.equalTo(2));

        String url = given().baseUri(videoUrl).header("Authorization", "Bearer " + token)
                .get("/api/v1/videos/" + videoId + "/download")
                .then().statusCode(200)
                .extract().path("url");

        int entradas = 0;
        try (ZipInputStream zip = new ZipInputStream(new URL(url).openStream())) {
            while (zip.getNextEntry() != null) {
                entradas++;
            }
        }
        assertThat(entradas).isEqualTo(2);
    }

    @Test
    void doisVideosSaoProcessadosEmParalelo() {
        String token = registrarELogar("e2e-" + UUID.randomUUID() + "@fiap.com.br");

        String primeiro = enviarVideo(token);
        String segundo = enviarVideo(token);

        aguardarConclusao(token, primeiro);
        aguardarConclusao(token, segundo);

        given().baseUri(videoUrl).header("Authorization", "Bearer " + token)
                .get("/api/v1/videos")
                .then().statusCode(200)
                .body("total", org.hamcrest.Matchers.equalTo(2));
    }

    @Test
    void umUsuarioNaoEnxergaOVideoDeOutro() {
        String tokenA = registrarELogar("e2e-a-" + UUID.randomUUID() + "@fiap.com.br");
        String tokenB = registrarELogar("e2e-b-" + UUID.randomUUID() + "@fiap.com.br");

        String videoDeA = enviarVideo(tokenA);

        given().baseUri(videoUrl).header("Authorization", "Bearer " + tokenB)
                .get("/api/v1/videos/" + videoDeA)
                .then().statusCode(404);

        given().baseUri(videoUrl).header("Authorization", "Bearer " + tokenB)
                .get("/api/v1/videos")
                .then().statusCode(200)
                .body("total", org.hamcrest.Matchers.equalTo(0));
    }

    @Test
    void requisicaoSemTokenERecusada() {
        given().baseUri(videoUrl).get("/api/v1/videos").then().statusCode(401);
    }

    @Test
    void arquivoDeFormatoInvalidoERecusadoCom400() throws Exception {
        String token = registrarELogar("e2e-" + UUID.randomUUID() + "@fiap.com.br");
        File pdf = Files.writeString(Files.createTempFile("doc", ".pdf"), "nao sou video").toFile();

        given().baseUri(videoUrl).header("Authorization", "Bearer " + token)
                .multiPart("video", pdf)
                .post("/api/v1/videos")
                .then().statusCode(400);
    }
}
```

- [ ] **Step 4: Rodar o E2E contra o ambiente da Task 21**

```bash
docker compose up --build -d
cd e2e && ./mvnw test
```
Expected: PASS — os cinco testes verdes.

- [ ] **Step 5: Documentar no `README.md` da raiz**

Acrescente:
```markdown
## Testes de ponta a ponta

    docker compose up --build -d
    cd e2e && ./mvnw test

Cobrem: fluxo completo do upload ao ZIP, dois vídeos em paralelo, isolamento
entre usuários, exigência de token e recusa de formato inválido.
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "test: suite de ponta a ponta da fatia vertical

Percorre login, upload, processamento assincrono e download do ZIP, e
verifica que um usuario nao enxerga o video de outro."
```

---

## Critérios de conclusão da Fase 1

A fase 1 está pronta quando **todos** os itens abaixo forem verdadeiros:

- [ ] `./mvnw verify` passa nos quatro repositórios, com a verificação de cobertura do JaCoCo.
- [ ] `docker compose up --build` sobe o sistema sem nenhuma credencial AWS real.
- [ ] `cd e2e && ./mvnw test` passa com os cinco testes.
- [ ] Um vídeo de 2 s produz um ZIP com exatamente 2 frames PNG.
- [ ] Dois vídeos enviados em sequência imediata são processados pelas duas réplicas do worker.
- [ ] Requisição sem token responde `401`; vídeo de outro usuário responde `404`.
- [ ] Um arquivo corrompido leva o vídeo a `FAILED` com `errorCode` preenchido e visível na listagem.
- [ ] Os quatro repositórios estão no GitHub, cada um com README.

Cumpridos esses itens, existe uma demonstração gravável de ponta a ponta — e o
Plano 2 (AWS, gateway, notificação, CI/CD e observabilidade) pode começar.
