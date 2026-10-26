
# Dockerización de Spring PetClinic

## 1. Objetivo

El objetivo de esta práctica es desplegar Spring PetClinic utilizando Docker, aprendiendo a crear un Dockerfile que tenga en cuenta la seguridad y la optimización. También se desplegará la aplicación junto con una base de datos MySQL, tanto utilizando Docker CLI como Docker Compose.

Por último, se analizará la imagen creada con herramientas de seguridad para identificar posibles vulnerabilidades y aplicar las mejoras necesarias.

## 2. Creación del Dockerfile

Para empezar, elegí Spring PetClinic como aplicación de prueba, ya que es un proyecto Java que utiliza Maven y permite trabajar con una aplicación web real.

Inicialmente utilicé una imagen de Maven como base para la compilación, pero me indicaron que no podía utilizar Docker Hardened Images (DHI). Al revisar el proyecto, me di cuenta de que ya incluía un Maven Wrapper (`mvnw`), por lo que podía utilizar una imagen con JDK 17 y ejecutar Maven a través del Wrapper.

El Dockerfile quedó dividido en dos etapas: una para compilar la aplicación y otra para ejecutarla.

### Compilación de la aplicación

```Dockerfile
FROM eclipse-temurin:17 AS build
WORKDIR /app

COPY .mvn/ .mvn
COPY mvnw pom.xml ./

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw dependency:go-offline -B

COPY src ./src

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw clean package -DskipTests -B
```

Primero seleccioné una imagen con JDK 17 y preparé el directorio de trabajo. Después copié los archivos necesarios para utilizar Maven Wrapper y resolver las dependencias del proyecto.

También utilicé una caché para las dependencias de Maven, con el objetivo de acelerar las siguientes construcciones.

Finalmente, compilé la aplicación y generé el JAR que se utilizará para ejecutarla. Durante esta fase omití los tests para simplificar la construcción inicial, aunque queda pendiente decidir cómo integrarlos en el proceso final. 

Me ha ayudado bastante la guía de la imagen Maven en DockerHub: [Hardened Images catalog | Maven | Guides | Docker Hub](https://hub.docker.com/hardened-images/catalog/dhi/maven/guides)

En la guía se proporciona un Dockerfile de ejemplo para usar esa imagen base y justamente para desplegar PetClinic. Al final no usé esa imagen base, pero me ha ayudado a entender cómo es dockerizar una aplicación spring boot con maven.

### Ejecución de la aplicación

```Dockerfile
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
```

Para la segunda etapa utilicé una imagen JRE, ya que la aplicación necesita Java para ejecutarse, pero no necesita todas las herramientas utilizadas durante la compilación.

Copié únicamente el JAR generado en la primera etapa. De esta forma, evito incluir Maven y el código fuente en la imagen final.

También creé un usuario específico para ejecutar la aplicación en lugar de utilizar `root`, como primera medida de seguridad.

Por último, configuré el perfil `mysql` de Spring y el comando de arranque de la aplicación.

## 3. Conexión con MySQL

Una vez que la aplicación funcionaba, empecé a configurar una base de datos MySQL en un contenedor independiente.

Al principio tuve que entender cómo se comunican dos contenedores y por qué utilizar `localhost` en la configuración de Spring no funcionaba: dentro del contenedor de PetClinic, `localhost` hace referencia al propio contenedor, no al de MySQL.

Para solucionarlo, configuré una red Docker compartida y utilicé el nombre del contenedor MySQL como dirección de conexión.

También aproveché las variables de entorno que ya estaban definidas en la configuración de Spring para establecer la URL de la base de datos sin tener que modificar el código de la aplicación.

### Persistencia de los datos

Para evitar perder los datos al eliminar o recrear el contenedor de MySQL, creé un volumen llamado `mysql_data` y lo asocié al directorio donde MySQL almacena la información.

```
docker network create pet-network
docker volume create mysql_data
```

De esta forma, la red permite la comunicación entre los contenedores y el volumen permite conservar los datos independientemente del ciclo de vida del contenedor.

## 4. Despliegue con Docker CLI

Una vez construida la imagen de PetClinic, utilicé `docker run` para arrancar primero MySQL y después la aplicación.

```bash
docker run -d --name mysql_pet_container -v mysql_data:/var/lib/mysql -p 3306:3306 -e  MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=petclinic -e MYSQL_USER=petclinic -e MYSQL_PASSWORD=petclinic --network=pet-network mysql:9.7
```

```bash
docker run -d --name petclinic-app --network=pet-network -p 8000:8080 -e MYSQL_URL=jdbc:mysql://mysql_pet_container:3306/petclinic petclinic:latest
```

Durante este proceso configuré los puertos, las variables de entorno, la red compartida y el volumen persistente.

Publiqué el puerto 8080 de PetClinic en el puerto 8000 de mi máquina, de manera que podía acceder a la aplicación desde el navegador mediante `http://localhost:8000`.

Para comprobar el funcionamiento, utilicé `docker logs`, que me permitieron revisar el estado de los contenedores y detectar posibles errores durante el arranque.

## 5. Despliegue con Docker Compose

Después preparé un archivo `docker-compose.yaml` para definir los dos servicios, PetClinic y MySQL, en un único lugar.

La idea era poder levantar toda la aplicación en local con un solo comando, sin tener que ejecutar manualmente cada contenedor.

En el archivo definí las imágenes, los puertos, las variables de entorno y el volumen de MySQL. También configuré el nombre del servicio de base de datos para que PetClinic pudiera conectarse a él a través de la red creada automáticamente por Compose.

Para ejecutar el despliegue utilicé:

```
docker compose up -d
```

Y para comprobar su estado:

```
docker compose ps
docker compose logs
```

Durante esta parte tuve que distinguir entre los volúmenes creados y gestionados por Compose y los volúmenes externos, que deben existir previamente.

**TODO**
Mejorar la configuración de seguridad de MySQL

## 6. Seguridad y optimización

Las principales medidas aplicadas hasta ahora son:

- **Construcción multi-stage:** separa la compilación de la ejecución y evita incluir Maven en la imagen final.
- **Caché de dependencias:** permite reutilizar las dependencias de Maven entre construcciones.
- **Usuario no privilegiado:** la aplicación se ejecuta con el usuario `petclinic` en lugar de `root`.
- **Configuración mediante variables de entorno:** permite configurar la conexión a MySQL sin modificar el código fuente.
- **Volumen persistente:** permite conservar los datos de MySQL al recrear el contenedor.

**TODO**
Más medidas de hardening del Dockerfile
## 7. Auditoría de la imagen

La siguiente fase consiste en analizar la imagen con Trivy y utilizar una herramienta de linting para revisar el Dockerfile.

**TODO**
Analizar la imagen final con Trivy y linting con KICS
## 8. Problemas encontrados

Durante el ejercicio he tenido que familiarizarme con el proceso de compilación de Maven, el funcionamiento del Maven Wrapper y sobre todo, entender cómo ejecutar una aplicación Spring y sus fases de compilación; la comunicación entre contenedores y la persistencia mediante volúmenes.

También he tardado bastante en entender y encontrar las variables de entorno que debo configurar, tanto para la app en sí, como para la base de datos mysql. Por ejemplo, tuve que investigar los archivos `/src/main/resources/*.properties`, más específicamente en ``
``application-mysql.properties`` existe la la línea :

``spring.datasource.url=${MYSQL_URL:jdbc:mysql://localhost/petclinic}``

Ahí es cuando caí que ``MYSQL_URL`` era la variable de entorno que necesitaba configurar con ese formato al arrancar el contenedor de la app para que se comunicara con la base de datos.

**TODO**
Desarrollar más problemas encontrados