package com.example.runnerplatform.web;

import static org.hamcrest.Matchers.containsString;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

/**
 * HTTP-level tests for the public API surface.
 */
@SpringBootTest
@AutoConfigureMockMvc
class ApiControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void rootServesTheStaticLandingPage() throws Exception {
        mockMvc.perform(get("/"))
            .andExpect(status().isOk())
            .andExpect(content().string(containsString("GitHub Self-Hosted Runner Platform")));
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
