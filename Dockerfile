
FROM eclipse-temurin:17@sha256:7c480ddf72df6c2aaa4280e5297d3b379884a1843519caef0b7f3ec145ed55ff AS build

WORKDIR /app

COPY .mvn/ .mvn
COPY mvnw pom.xml ./

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw dependency:go-offline -B

COPY src ./src

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw clean package -DskipTests -B

FROM eclipse-temurin:27_35-jre-alpine-3.24 AS runtime

RUN apk upgrade --no-cache brotli-libs

RUN addgroup -g 1001 petclinic && \
    adduser -D -u 1001 -G petclinic \
    -s /sbin/nologin petclinic

WORKDIR /app

COPY --from=build --chmod=0444 \
    /app/target/spring-petclinic-*.jar app.jar

USER petclinic

ENV SPRING_PROFILES_ACTIVE=mysql

EXPOSE 8080

LABEL org.opencontainers.image.title="Spring PetClinic" \
      org.opencontainers.image.description="Spring PetClinic desplegada con Docker y MySQL" \
      org.opencontainers.image.source="https://github.com/RaulAlcauter/spring-petclinic"

ENTRYPOINT ["java", "-jar", "app.jar"]
