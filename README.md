# Dockerización de Spring PetClinic

## 1. Objetivo

El objetivo de esta práctica es desplegar Spring PetClinic utilizando Docker, aprendiendo a crear un Dockerfile que tenga en cuenta la seguridad y la optimización. También se desplegará la aplicación junto con una base de datos MySQL, tanto utilizando Docker CLI como con Docker Compose.

Por último, se analizará la imagen creada con herramientas de seguridad para identificar posibles vulnerabilidades y aplicar las mejoras necesarias.

## 2. Creación del Dockerfile

Inicialmente utilicé una imagen de Maven como base para la compilación, pero me indicaron que no podía utilizar Docker Hardened Images (DHI). Al revisar el proyecto, me di cuenta de que ya incluía un Maven Wrapper (`mvnw`), por lo que podía utilizar una imagen con JDK 17 y ejecutar Maven a través del Wrapper.

El Dockerfile quedó dividido en dos etapas: una para compilar la aplicación y otra para ejecutarla.

### Compilación de la aplicación

```Dockerfile
FROM eclipse-temurin:17@sha256:7c480ddf72df6c2aaa4280e5297d3b379884a1843519caef0b7f3ec145ed55ff AS build

WORKDIR /app

COPY .mvn/ .mvn
COPY mvnw pom.xml ./

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw dependency:go-offline -B

COPY src ./src

RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw clean package -DskipTests -B
```

Primero seleccioné una imagen con JDK 17 y preparé el directorio de trabajo. Después copié los archivos necesarios para utilizar Maven Wrapper y descargar las dependencias del proyecto.

También utilicé una caché para las dependencias de Maven, con el objetivo de acelerar las siguientes construcciones. Copio primero los archivos de Maven y después el código fuente para que los cambios únicamente en `src` no destruyan la cache.

Luego compilé la aplicación y generé el JAR que se utilizará para ejecutarla. Durante la construcción de la imagen omití los tests con `-DskipTests`, ya que se validan por separado y no quiero mezclar la fase de pruebas del pipeline con la construcción de la imagen de ejecución.

Me ha ayudado bastante la guía de la imagen Maven en DockerHub: [Hardened Images catalog | Maven | Guides | Docker Hub](https://hub.docker.com/hardened-images/catalog/dhi/maven/guides). Aunque al final no utilicé esa imagen como base, la guía me ayudó a entender cómo dockerizar una aplicación Spring Boot con Maven.

### Ejecución de la aplicación

La etapa final del Dockerfile es la siguiente:

```Dockerfile
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
```

Para la segunda etapa utilicé una imagen JRE, ya que la aplicación necesita Java para ejecutarse, pero no necesita todas las herramientas utilizadas durante la compilación. Copio únicamente el JAR generado en la primera etapa, por lo que el wrapper Maven y el código fuente no se incorporan a la imagen final.

He fijado las imágenes base con sus digests, así utilizo una imagen concreta.

También he creado un usuario específico llamado `petclinic`, con UID y GID `1001`, para ejecutar la aplicación en lugar de utilizar `root`. He configurado su shell como `/usr/sbin/nologin` y he usado `-M` para no crear un directorio personal innecesario.

El JAR se copia con permisos `0444`, que permiten leerlo, pero no modificarlo. Inicialmente había utilizado `--chown=1001:1001`, pero KICS señaló que el ejecutable de una aplicación debería poder ser propiedad de `root`, ya que el usuario de ejecución solo necesita leerlo. Quité `--chown` y mantuve los permisos de lectura; Docker asigna el archivo a `root` por defecto.

Por último, configuré el perfil `mysql`, el puerto de la aplicación, las etiquetas OCI para identificar la imagen y el ``ENTRYPOINT``. El `ENTRYPOINT` está en formato JSON para iniciar Java directamente, sin una shell intermedia.

Para construir la imagen localmente, desde la raíz del proyecto:

```
docker build -t petclinic:latest .
```

## 3. Conexión con MySQL

Una vez que la aplicación funcionaba, configuré una base de datos MySQL en un contenedor independiente. Tuve que entender cómo se comunican dos contenedores y por qué utilizar `localhost` en la configuración de Spring no funcionaba: dentro de PetClinic, `localhost` hace referencia al propio contenedor, no al de MySQL.

En `src/main/resources/application-mysql.properties` encontré una configuración de este estilo:

```
spring.datasource.url=${MYSQL_URL:jdbc:mysql://localhost/petclinic}
```

Esto me hizo identificar `MYSQL_URL` como la variable de entorno que debía configurar para que PetClinic se conectara a la base de datos. En Docker Compose utilizo `jdbc:mysql://mysql-petclinic/petclinic`, donde `mysql-petclinic` es el nombre del servicio de MySQL en la red de Compose. En el despliegue con Docker CLI utilizo el nombre del contenedor MySQL dentro de una red compartida.

### Variables de entorno y credenciales

He creado un archivo `.env` para no hardcodear las credenciales directamente en `docker-compose.yml`. El archivo contiene estas variables, con los valores reales configurados localmente:

```
MYSQL_ROOT_PASSWORD=<contraseña-de-root>
MYSQL_USER=petclinic
MYSQL_PASSWORD=<contraseña-del-usuario>
MYSQL_PASS=<contraseña-del-usuario>
MYSQL_DATABASE=petclinic
```

He añadido `.env` a `.gitignore` y `.dockerignore` para evitar subirlo al repositorio o incluirlo en el contexto de construcción de la imagen.

### Persistencia y red

Para conservar los datos al eliminar o recrear el contenedor de MySQL, utilizo un volumen llamado `spring-petclinic_mysql_data`, montado en `/var/lib/mysql`. 

Docker Compose crea automáticamente una red para el proyecto. Los servicios pueden encontrarse por su nombre dentro de esa red, de modo que no es necesario publicar el puerto de MySQL en el host para que PetClinic se conecte.

Cuando se utiliza Docker CLI de forma independiente, creo una red llamada `pet-network` y conecto ambos contenedores a ella. Esa red es distinta de la red que genera Compose automáticamente.

## 4. Despliegue por separado con Docker CLI

También puedo desplegar la aplicación y la base de datos por separado mediante `docker run`. Aquí creo o reutilizo la red `pet-network` y el volumen externo `mysql_data`.
### Preparación

Desde la raíz del proyecto, construyo la imagen de PetClinic, la red y el volumen si no existía.

```bash
docker build -t petclinic:latest .

docker network create pet-network

docker volume create spring-petclinic_mysql_data
```
### Arrancar MySQL

Arranco primero MySQL, usando el volumen persistente, la red compartida y las variables de entorno creadas. No publico el puerto `3306` en el host porque solo necesita ser accesible desde PetClinic:

```bash
docker run --rm -d \
  --name mysql-petclinic \
  --network pet-network \
  --memory=512m \
  --cpus=1.0 \
  --security-opt no-new-privileges:true \
  -v spring-petclinic_mysql_data:/var/lib/mysql \
  --env-file .env \
  mysql:9.7
```

### Arrancar PetClinic

Cuando MySQL está preparado, arranco PetClinic en la misma red. Mantengo los controles que también uso en Docker Compose: límite de memoria y CPU, sistema de archivos raíz de solo lectura, `/tmp` escribible mediante `tmpfs`, eliminación de capacidades y `no-new-privileges`.

```bash
docker run --rm -d \
  --name petclinic-app \
  --network pet-network \
  -p 8000:8080 \
  --memory=512m \
  --cpus=1.0 \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --env-file .env \
  -e MYSQL_URL=jdbc:mysql://mysql-petclinic:3306/petclinic \
  petclinic:latest
```

El Dockerfile ya establece `SPRING_PROFILES_ACTIVE=mysql` y el usuario `petclinic`, así que no necesito volver a definirlos en `docker run`. El puerto `8000` del host se conecta al puerto `8080` de la aplicación. MySQL no publica ningún puerto en el host.
## 5. Despliegue con Docker Compose

Después preparé un archivo `docker-compose.yml` para definir los dos servicios en un único lugar. Compose crea automáticamente una red para el proyecto, por lo que PetClinic puede conectarse a MySQL usando el nombre `mysql-petclinic`.

La configuración actual es:

```YAML
services:
  mysql-petclinic:
    container_name: mysql-petclinic
    image: mysql:9.7
    mem_limit: 512m
    cpus: 1.0
    security_opt:
      - no-new-privileges:true
    volumes:
      - mysql_data:/var/lib/mysql
    env_file:
      - .env

  

  petclinic-app:
    container_name: petclinic-app
    image: petclinic:latest
    mem_limit: 512m
    cpus: 1.0
    read_only: true
    tmpfs:
      - /tmp
    ports:
      - "8000:8080"
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      MYSQL_URL: jdbc:mysql://mysql-petclinic:3306/petclinic

volumes:
  mysql_data:
```


No he añadido un `ports` a MySQL: solo PetClinic publica `8000:8080`. Esto reduce la exposición de la base de datos al host, pero MySQL sigue siendo accesible para los contenedores conectados a la misma red de Compose.

### Arrancar y comprobar con Compose

Primero construyo la imagen de PetClinic:

```
docker build -t petclinic:latest .
```

Después arranco los dos servicios:

```
docker compose up
```

Para detener los servicios sin borrar los datos persistentes utilizo:

```
docker compose down
```
## 6. Seguridad y optimización

### Imagen base

- **Elegir una imagen base oficial y mantenida:** He elegido `eclipse-temurin:17` para compilar la aplicación y `eclipse-temurin:17-jre` para ejecutarla.
- **Elegir una variante adecuada:** He utilizado una imagen JDK para compilar y una JRE para ejecutar. Así evito incluir herramientas de compilación innecesarias en la imagen final.
- **Fijar las imágenes mediante digest:** He añadido los digests SHA-256 de las imágenes base para obtener construcciones más reproducibles. Para recibir futuras actualizaciones de seguridad, tendré que revisar y actualizar esos digests de forma deliberada.
- **Revisar vulnerabilidades conocidas:** He escaneado la imagen final `petclinic:latest` con Trivy. El informe detectó 57 vulnerabilidades en paquetes del sistema operativo (53 medias y 4 bajas) y 16 en las dependencias Java del JAR (5 críticas, 6 altas y 5 medias). No se detectaron vulnerabilidades altas o críticas en el bloque de paquetes del sistema operativo, pero sí en las dependencias Java. (Pendiente de consutla y de revisión). Los resultados se guardan en `reports/security/trivy/`.

### Construcción del Dockerfile

- **Separar compilación y ejecución:** He utilizado una construcción multietapa para compilar la aplicación en una etapa independiente y copiar únicamente el JAR a la imagen final.
- **Usar `.dockerignore`:** He creado `.dockerignore` para excluir del contexto de construcción archivos innecesarios, como `.git`, `target/`, archivos temporales y configuraciones locales sensibles.
- **Copiar solo lo necesario:** He utilizado instrucciones `COPY` específicas y copio al runtime únicamente el JAR ejecutable.
- **No introducir secretos en la imagen:** He configurado las credenciales de MySQL en `.env` y las referencio desde Compose mediante variables de entorno. El archivo `.env` está excluido de Git y del contexto de construcción.
- **Reducir paquetes y dependencias:** La etapa de compilación utiliza JDK y Maven Wrapper; la imagen final contiene la JRE necesaria para ejecutar Java.
- **Optimizar la caché de compilación:** He ordenado las instrucciones `COPY` para descargar las dependencias antes de copiar el código fuente y he utilizado `--mount=type=cache,target=/root/.m2` para conservar la caché de Maven entre construcciones.
- **Ejecutar las pruebas separadas de la construcción:** La imagen se construye con `-DskipTests`; las pruebas se ejecutan por separado antes de reconstruir la imagen.

### Usuario y permisos

- **Crear un usuario no root:** He creado el usuario `petclinic` para ejecutar Java en lugar de utilizar `root`.
- **Definir UID/GID de forma deliberada:** He asignado UID y GID `1001` al usuario y grupo `petclinic`.
- **Usar `USER` para la ejecución:** He añadido `USER petclinic` para que la aplicación se ejecute con ese usuario no privilegiado.
- **Limitar los permisos del JAR:** He eliminado `--chown` tras el hallazgo de KICS y copio el JAR como propiedad de `root`, con permisos `0444`. Así puede leerse, pero no modificarse.
- **Evitar una shell innecesaria:** He configurado `/usr/sbin/nologin` y la opción `-M` para el usuario `petclinic`. La aplicación se inicia mediante `ENTRYPOINT ["java", "-jar", "app.jar"]`.

### Ejecución y configuración

- **Usar `ENTRYPOINT` en formato JSON:** He configurado el arranque para ejecutar directamente Java, sin una shell intermedia.
- **Configurar credenciales mediante entorno:** He utilizado variables de entorno para las credenciales, evitando escribirlas en el Dockerfile o incluirlas en la imagen.
- **Definir `EXPOSE` correctamente:** He declarado `EXPOSE 8080` en el Dockerfile. La publicación real del puerto se realiza aparte mediante Compose o `docker run`.
- **Añadir metadatos útiles:** He incorporado etiquetas OCI para identificar la aplicación, describir su función y referenciar su repositorio de origen.

### Controles de ejecución (Docker/Compose)

- **No usar `privileged`:** No he habilitado el modo privilegiado en los servicios.
- **Evitar la escalada de privilegios:** He configurado `no-new-privileges:true` en ambos contenedores.
- **Reducir las capacidades de PetClinic:** He configurado `cap_drop: [ALL]` en el servicio de la aplicación. Intenté aplicar esta restricción a MySQL, pero impedía su inicialización y el acceso al volumen persistente, así que la retiré de MySQL.
- **Sistema de archivos de solo lectura:** He configurado `read_only: true` en PetClinic. Spring Boot necesita crear un directorio temporal para Tomcat, por lo que he habilitado `/tmp` mediante `tmpfs`. Después he comprobado que la aplicación arranca y responde con HTTP `200`.
- **Reducir la exposición de MySQL:** He eliminado la publicación del puerto `3306` en el host. PetClinic se conecta a MySQL por la red interna de Docker.
- **Limitar recursos:** He establecido límites de memoria (`mem_limit: 512m`) y CPU (`cpus: 1.0`) para ambos contenedores.
- **Proteger la persistencia:** He mantenido el volumen externo `mysql_data` montado en `/var/lib/mysql`. He comprobado que PetClinic no monta directamente ese volumen.
- **No montar el socket Docker:** He comprobado que ninguno de los contenedores monta `/var/run/docker.sock`.
- **Mantener los perfiles de seguridad predeterminados:** No he configurado opciones para deshabilitar seccomp ni otros perfiles predeterminados. Ambos servicios mantienen `no-new-privileges:true`.
- **Healthcheck:** No he añadido una instrucción `HEALTHCHECK`. KICS la detecta como hallazgo de severidad baja; he decidido dejarla pendiente en este ejercicio.

## 7. Auditoría de la imagen

### Trivy: análisis de vulnerabilidades

He ejecutado Trivy contra `petclinic:latest` para analizar los paquetes del sistema operativo y las dependencias Java que detecta dentro del JAR. El resultado inicial encontró vulnerabilidades de severidad media y baja en paquetes del sistema operativo y vulnerabilidades críticas, altas y medias en dependencias Java, entre ellas Spring WebMVC, Tomcat y Jackson.

He guardado los informes de Trivy en `reports/security/trivy/` en formato de texto y JSON. La revisión de las dependencias Java queda pendiente: antes de actualizar versiones quiero revisar el resultado y comprobar qué cambios corresponden al proyecto y cuáles a la imagen base.

Ejemplos de comandos para generar los informes son:

```bash
mkdir -p reports/security/trivy

trivy image --format table \
  --output reports/security/trivy/trivy-image.txt \
  petclinic:latest

trivy image --format json \
  --output reports/security/trivy/trivy-image.json \
  petclinic:latest
```

### KICS: análisis estático del Dockerfile

He utilizado KICS para analizar el `Dockerfile` sin arrancar la aplicación. He guardado los informes JSON y HTML en `reports/security/`.

El comando utilizado es:

```bash
docker run --rm \
  -v "$PWD:/path:ro" \
  -v "$PWD/reports/security:/reports" \
  checkmarx/kics:v2.2.0 scan \
  -p /path/Dockerfile \
  -t Dockerfile \
  -o /reports \
  --report-formats json,html \
  --output-name kics-dockerfile
```

En el primer análisis KICS encontró dos hallazgos de severidad baja: ausencia de `HEALTHCHECK` y uso de `--chown` en la instrucción `COPY` del JAR. Quité `--chown` y mantuve `--chmod=0444`, de manera que el JAR queda propiedad de `root` y se puede leer sin conceder permisos de escritura. Tras repetir el análisis, solo permaneció el hallazgo de `HEALTHCHECK`, que he decidido no implementar por ahora.

Después reconstruí la imagen y comprobé que la aplicación seguía funcionando con Docker Compose.
## 8. Problemas encontrados

Durante el ejercicio he tenido que familiarizarme con el proceso de compilación de Maven, el funcionamiento del Maven Wrapper y, sobre todo, entender cómo ejecutar una aplicación Spring y sus fases de compilación. También he tenido que aprender cómo se comunican dos contenedores y cómo funcionan los volúmenes persistentes.

También me costó encontrar las variables de entorno que debía configurar para la aplicación y para MySQL. Al revisar `application-mysql.properties`, encontré que `MYSQL_URL` se utiliza para definir la dirección JDBC. Así entendí que tenía que configurar la URL con el nombre del servicio o contenedor MySQL, en vez de utilizar `localhost`.

Durante el endurecimiento de Docker Compose, intenté eliminar todas las capacidades de Linux del contenedor de MySQL mediante `cap_drop: [ALL]`. Esto provocó errores al cambiar al usuario `mysql` y al acceder a los datos persistidos. Tras comprobar que seguían apareciendo errores de permisos, retiré la restricción de capabilities de MySQL y mantuve `cap_drop: [ALL]` únicamente en PetClinic. Después verifiqué que MySQL arrancaba, la aplicación se conectaba a la base de datos y PetClinic respondía con HTTP `200`.

Al activar `read_only: true` en PetClinic, Spring Boot no pudo crear el directorio temporal de Tomcat y el contenedor terminó con el error `Read-only file system` en `/tmp`. Lo solucioné montando `/tmp` como `tmpfs`, con lo que mantuve el sistema de archivos raíz en solo lectura sin impedir el arranque de la aplicación.

También comprobé que la publicación de puertos no es necesaria para conectar ambos contenedores. El puerto `3306` de MySQL se puede mantener sin publicar en el host, mientras PetClinic lo alcanza a través de la red de Docker. En Compose únicamente se publica el puerto `8000` de la aplicación.

Por último, y no se por qué, me pasé unas tres horas sin saber por que las variables de entorno creadas no se pasaban bien con el formato: `${}`,  hasta que decidí usar ``env_file: .env`` en el docker-compose.yml y en CLI pasarlo como parámetro con `--env-file: .env `.