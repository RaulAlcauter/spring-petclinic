
FROM eclipse-temurin:17@sha256:7c480ddf72df6c2aaa4280e5297d3b379884a1843519caef0b7f3ec145ed55ff AS build

WORKDIR /app

COPY .mvn/ .mvn
COPY mvnw pom.xml ./

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw dependency:go-offline -B

COPY src ./src

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw clean package -DskipTests -B

FROM eclipse-temurin:17-jre@sha256:bdc6c4d91efc63515085e1288be79290cb4806c5e5148dd8035d49b24fa55707 AS runtime

RUN groupadd -g 1001 petclinic && \
    useradd -u 1001 -g petclinic \
    -s /usr/sbin/nologin -M petclinic

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
