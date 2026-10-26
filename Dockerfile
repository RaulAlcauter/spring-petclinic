
FROM eclipse-temurin:17 AS build

WORKDIR /app

COPY .mvn/ .mvn
COPY mvnw pom.xml ./

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw dependency:go-offline -B

COPY src ./src

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw clean package -DskipTests -B

FROM eclipse-temurin:17-jre AS runtime

RUN groupadd -g 1001 petclinic && \
    useradd -u 1001 -g petclinic -s /bin/sh -m petclinic

WORKDIR /app

COPY --from=build /app/target/spring-petclinic-*.jar app.jar

RUN chown petclinic:petclinic app.jar

USER petclinic

ENV SPRING_PROFILES_ACTIVE=mysql

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]
