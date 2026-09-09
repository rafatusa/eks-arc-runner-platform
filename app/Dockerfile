# NOTE: no `# syntax=docker/dockerfile:1` directive here on purpose.
# The frontend directive is a BuildKit-only feature and the legacy builder
# rejects it. The CI runner image ships the docker CLI without the buildx
# plugin, so the build stages run with DOCKER_BUILDKIT=0. Nothing below uses
# BuildKit-only syntax (no --mount, no heredocs, no --link), so this file
# builds identically under either builder.

##############################################################################
# Build stage — compiles the Spring Boot fat jar with the pinned JDK.
##############################################################################
FROM eclipse-temurin:21-jdk-jammy AS build

WORKDIR /workspace

# Wrapper + build definition first: this layer is cached until the build changes.
COPY gradlew ./gradlew
COPY gradle ./gradle
COPY settings.gradle build.gradle ./
COPY config ./config
RUN chmod +x ./gradlew && ./gradlew --no-daemon --version

# Sources change most often, so they are copied last.
COPY src ./src

RUN ./gradlew bootJar --no-daemon -x test

##############################################################################
# Runtime stage — JRE only, non-root.
##############################################################################
FROM eclipse-temurin:21-jre-jammy AS runtime

# curl is needed by the container healthcheck; the JRE image does not ship it.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --system --gid 10001 app; \
    useradd --system --uid 10001 --gid app --home-dir /app --shell /usr/sbin/nologin app; \
    mkdir -p /app; \
    chown app:app /app

WORKDIR /app

COPY --from=build --chown=app:app /workspace/build/libs/app.jar /app/app.jar

USER app

ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseSerialGC -Djava.io.tmpdir=/tmp" \
    SERVER_PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl --fail --silent --show-error http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/bin/sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
