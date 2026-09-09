package com.example.runnerplatform.e2e;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.notNullValue;

import io.restassured.RestAssured;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;

/**
 * REST Assured tests executed against a DEPLOYED instance of the service.
 *
 * <p>Runs only in the validation pipeline (tag {@code e2e}); the base URL comes from
 * the {@code base.url} system property, which the pipeline resolves from the ALB
 * address published by the ingress.</p>
 */
@Tag("e2e")
class RestAssuredApiIT {

    @BeforeAll
    static void configureBaseUri() {
        final String baseUrl = System.getProperty("base.url", "http://localhost:8080");
        RestAssured.baseURI = baseUrl;
        RestAssured.useRelaxedHTTPSValidation();
    }

    @Test
    void landingPageIsServed() {
        given()
            .when().get("/")
            .then()
            .statusCode(200)
            .body(containsString("GitHub Self-Hosted Runner Platform"));
    }

    @Test
    void healthEndpointReportsUp() {
        given()
            .when().get("/health")
            .then()
            .statusCode(200)
            .body("status", equalTo("UP"))
            .body("hostname", notNullValue());
    }

    @Test
    void helloEndpointGreetsCaller() {
        given()
            .queryParam("name", "eks")
            .when().get("/hello")
            .then()
            .statusCode(200)
            .body("message", equalTo("Hello, eks!"));
    }

    @Test
    void actuatorHealthIsUp() {
        given()
            .when().get("/actuator/health")
            .then()
            .statusCode(200)
            .body("status", equalTo("UP"));
    }
}
