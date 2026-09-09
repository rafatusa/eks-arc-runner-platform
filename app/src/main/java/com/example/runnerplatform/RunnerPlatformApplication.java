package com.example.runnerplatform;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Entry point for the sample service deployed by the self-hosted runner platform.
 */
@SpringBootApplication
public class RunnerPlatformApplication {

    /**
     * Boots the Spring application context.
     *
     * @param args command line arguments
     */
    public static void main(final String[] args) {
        SpringApplication.run(RunnerPlatformApplication.class, args);
    }
}
