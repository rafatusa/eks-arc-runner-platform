package com.example.runnerplatform.web;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.core.io.ClassPathResource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.util.StreamUtils;

/**
 * HTTP-level tests for the JSON endpoints, plus a guard on the static landing page.
 *
 * <p>The {@code /} route is served by Spring's ResourceHttpRequestHandler. Under
 * MockMvc that handler neither writes the body nor sets the Content-Type header —
 * both are produced by the servlet container's write path, which MockMvc does not
 * execute — so the route's HTTP behaviour is not assertable at this level. It is
 * verified against the real deployment instead, by
 * {@code scripts/ci/smoke-test.sh} and
 * {@code RestAssuredApiIT#landingPageIsServed()}. What IS worth guarding here is
 * that the resource those checks depend on exists and carries the right content.</p>
 */
@SpringBootTest
@AutoConfigureMockMvc
class ApiControllerTest {

    @Autowired
    private MockMvc mockMvc;

    /**
     * If index.html is deleted or emptied, `/` starts returning 404 in production.
     */
    @Test
    void landingPageResourceIsPresentAndBranded() throws Exception {
        final ClassPathResource page = new ClassPathResource("static/index.html");
        assertThat(page.exists()).isTrue();

        final String html;
        try (var input = page.getInputStream()) {
            html = StreamUtils.copyToString(input, StandardCharsets.UTF_8);
        }
        assertThat(html).contains("GitHub Self-Hosted Runner Platform");
        assertThat(html).contains("/health");
        assertThat(html).contains("/hello");
    }

    @Test
    void healthReportsUp() throws Exception {
        mockMvc.perform(get("/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.status").value("UP"))
            .andExpect(jsonPath("$.version").exists())
            .andExpect(jsonPath("$.hostname").exists())
            .andExpect(jsonPath("$.timestamp").exists());
    }

    @Test
    void helloUsesDefaultName() throws Exception {
        mockMvc.perform(get("/hello"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.message").value("Hello, world!"))
            .andExpect(jsonPath("$.servedBy").exists())
            .andExpect(jsonPath("$.version").exists());
    }

    @Test
    void helloGreetsProvidedName() throws Exception {
        mockMvc.perform(get("/hello").param("name", "runner"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.message").value("Hello, runner!"));
    }

    @Test
    void actuatorHealthIsExposed() throws Exception {
        mockMvc.perform(get("/actuator/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.status").value("UP"));
    }
}
