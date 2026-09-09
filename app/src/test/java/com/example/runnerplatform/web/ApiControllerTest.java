package com.example.runnerplatform.web;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.core.io.ClassPathResource;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.util.StreamUtils;

/**
 * HTTP-level tests for the public API surface.
 */
@SpringBootTest
@AutoConfigureMockMvc
class ApiControllerTest {

    @Autowired
    private MockMvc mockMvc;

    /**
     * The landing page is a STATIC resource served by Spring's
     * ResourceHttpRequestHandler, which streams the file rather than rendering
     * it into the mock response buffer — so MockMvc cannot assert on its body.
     * The serving contract (200 + HTML) is asserted here; the page's actual
     * content is asserted against the deployed app by RestAssuredApiIT.
     */
    @Test
    void rootServesHtmlLandingPage() throws Exception {
        mockMvc.perform(get("/"))
            .andExpect(status().isOk())
            .andExpect(content().contentTypeCompatibleWith(MediaType.TEXT_HTML));
    }

    /**
     * Guards the resource the route above depends on: if index.html is deleted
     * or emptied, `/` would start returning a 404 in production.
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
