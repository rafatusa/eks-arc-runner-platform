package com.example.runnerplatform.web;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * JSON endpoints of the sample service.
 *
 * <p>The landing page at {@code /} is served by Spring from
 * {@code src/main/resources/static/index.html}; it reads {@code /health} in the
 * browser to display the version and the serving pod.</p>
 */
@RestController
public class ApiController {

    /** Application version, surfaced so a rollout can be confirmed from outside. */
    private final String appVersion;

    /** Hostname of the serving pod, demonstrating load balancing across replicas. */
    private final String hostname;

    /**
     * Creates the controller.
     *
     * @param version application version injected from configuration
     */
    public ApiController(@Value("${app.version:unknown}") final String version) {
        this.appVersion = version;
        this.hostname = resolveHostname();
    }

    private static String resolveHostname() {
        final String fromEnv = System.getenv("HOSTNAME");
        return fromEnv == null || fromEnv.isBlank() ? "unknown" : fromEnv;
    }

    /**
     * Lightweight status endpoint used by probes, the ALB and the smoke tests.
     *
     * @return a status document
     */
    @GetMapping(value = "/health", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> health() {
        final Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", "UP");
        body.put("version", appVersion);
        body.put("hostname", hostname);
        body.put("timestamp", Instant.now().toString());
        return body;
    }

    /**
     * Greeting endpoint.
     *
     * @param name optional name to greet
     * @return a greeting document
     */
    @GetMapping(value = "/hello", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> hello(@RequestParam(defaultValue = "world") final String name) {
        final Map<String, Object> body = new LinkedHashMap<>();
        body.put("message", "Hello, " + name + "!");
        body.put("servedBy", hostname);
        body.put("version", appVersion);
        return body;
    }
}
