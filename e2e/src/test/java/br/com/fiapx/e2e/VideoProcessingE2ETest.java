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
