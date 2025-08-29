---
title: Minimalistic Java Container Images
date: 2025-08-24 16:20:09 +/-1234
categories: [Tutorial]
tags: [java, spring-boot, gradle, docker, minimalistic, graalvm, upx, custom-jre]
toc: true
comments: true
datatable: true
math: false
mermaid: false
---

As we know, [3 billion devices run Java](https://www.reddit.com/r/ProgrammerHumor/comments/tooj3d/3_billion_devices_run_java/). Despite the plethora of blogs against it, this language has cemented itself in enterprise code throughout the ages. Frameworks like Spring and build tools like Gradle have long reached a state of maturity in the ecosystem. Thus, it doesn't look like they're going away soon.

However, something that always bugged me when developing Java applications was the size of the resulting container images. It is fairly simple to reach 1GB while "just" developing an app with a database connection and some metrics. In microservice-based architectures, that can add up fairly quickly. That's why in this blog, I'll focus on what I found out when trying to make Java container images as small as possible. Here's how I managed to make a container **20x** (!) smaller.

## What To Expect From This

Before you start copy-pasting everything from here, I think it's only fair you know what you're getting in to. This tutorial is only aimed at Spring Boot projects built with Gradle! The reason behind it is that there are way less Gradle-based tutorials out there compared to Maven. In addition, I personally prefer tinkering with a DSL than raw XML files.

I will be working on [this](https://github.com/kristi-balla/java-demo) repository. It is a simple HTMX application that prints out the current time. In addition, it exposes some metrics to Prometheus. All `Dockerfiles` and configuration I reference here will be found there. If you want to measure the following metrics on your own, I have also uploaded a convenience script.

In the following, I will show you my thought process and how I got from a naive `Dockerfile` to one building a mostly statically linked and compressed binary.

## Naive Implementation

```Dockerfile
FROM gradle:8.14.3-jdk21 AS build

WORKDIR /app
COPY . .

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=10 CMD curl -f http://localhost:8080/actuator/health || exit 1
CMD [ "gradle", "bootRun" ]
```

This `Dockerfile` is where I started at. It doesn't even build the application explicitly, but just starts off by running the server. It also defines a `HEALTHCHECK` that will be used by the benchmarking script later on.

## Multi Stage

Since the [naive](#naive-implementation) implementation contains all the build dependencies and tools in the resulting image, it is thick. We can mitigate this by splitting the building and running into two stages:

```Dockerfile
FROM gradle:8.14.3-jdk21 AS build

WORKDIR /app
COPY . .

RUN gradle bootJar

FROM gcr.io/distroless/java21-debian12:debug

COPY --from=build /app/build/libs/naive-0.0.1-SNAPSHOT.jar app.jar

HEALTHCHECK --interval=5s --timeout=15s --start-period=20s --retries=20 CMD ["wget", "-q", "--spider", "http://localhost:8080/actuator/health"]
ENTRYPOINT [ "java", "-jar", "app.jar" ]
```

A better approach to this would have been adding another stage to build the dependencies separately from the application code. That would have benefited from Docker's layered caching. However, the increase in build time and management overhead isn't worth it for the size of this image.

## Custom JRE

The [multi-stage](#multi-stage) implementation moves the fat JAR in another stage. Yet that base image still contains some bloatware and unnecessary modules. The JRE of the distroless base image is still significantly contributing to the size of our image. It contains a lot of modules the application might *potentially* need, but doesn't actually use. However, you as a developer know (or can easily find out 😜) exactly what your application needs and can restrict the number of those modules to the absolutely necessary:

```Dockerfile
FROM gradle:8.14.3-jdk21 AS build

WORKDIR /app
COPY . .

RUN gradle bootJar

FROM eclipse-temurin:21 AS custom-jre

WORKDIR /custom

COPY --from=build /app/build/libs/naive-0.0.1-SNAPSHOT.jar app.jar

RUN jar -xf app.jar

RUN jdeps \
    --class-path 'BOOT-INF/lib/*' \
    --ignore-missing-deps \
    --multi-release 21 \
    --print-module-deps \
    --recursive \
    app.jar > dependencies.txt

RUN jlink \
    --add-modules $(cat dependencies.txt) \
    --compress=zip-9 \
    --no-header-files \
    --no-man-pages \
    --output jre \
    --strip-debug

FROM debian:12-slim

WORKDIR /prod
COPY --from=custom-jre /custom/jre jre
COPY --from=build /app/build/libs/naive-0.0.1-SNAPSHOT.jar app.jar

RUN apt-get -qqy update && \
    apt-get -qqy install --no-install-recommends wget && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/prod/jre/bin:$PATH"

HEALTHCHECK --interval=5s --timeout=15s --start-period=20s --retries=20 CMD ["wget", "-q", "--spider", "http://localhost:8080/actuator/health"]
ENTRYPOINT [ "java", "-jar", "app.jar" ]
```

{: .scroll}

One of the first things you may have noticed is that I firstly need to extract my JAR to read its dependencies. Since Spring Boot produces fat JARs with a wiring that `jdeps` **cannot** understand, I have to initially unpack it and point `jdeps` to the correct path.

When packaging a new JRE with `jlink`, one can choose from ten compression levels (0-9), with `0` being no compression and `9` being the most aggressive. When the option is left out, `jlink` defaults to 6. Despite this, I haven't had any issues with the maximal level of compression.

Another thing you may have noticed was that I swapped my base image from distroless to a slim Debian bookworm. The reasoning behind it is that the distroless Java image was too large by itself. I tried getting the `static-debian` variation to work, but `jlink` produces a dynamically linked Java binary, which doesn't play nicely with `static-debian`.

> While one could also reduce the build time here by hard-coding the dependencies needed, that could cause problems in the long run. A growing application may introduce new dependencies, which one would have to manually add
{: .prompt-info }

## Native

We may have reduced the size of the JRE, but our base image still contains it and its dependencies. In particular, the JVM would need to be spawned on each container start. Now, what if we compiled a statically linked executable? We would then be able to place it in a very minimalistic base image and benefit from potentially faster startup times:

```Dockerfile
FROM container-registry.oracle.com/graalvm/native-image:21-muslib AS builder
WORKDIR /workspace

RUN microdnf -y install findutils unzip wget xz zip && \
    wget -O grandel.zip https://services.gradle.org/distributions/gradle-8.14-bin.zip && \
    unzip grandel.zip -d /opt

COPY . .

ENV GRADLE_HOME="/opt/gradle-8.14"
ENV PATH="$GRADLE_HOME/bin:$PATH"
RUN gradle clean nativeCompile

FROM gcr.io/distroless/static-debian12:debug
COPY --from=builder /workspace/build/native/nativeCompile/htmx /app

HEALTHCHECK --interval=5s --timeout=15s --start-period=2s --retries=20 CMD ["wget", "-q", "--spider", "http://localhost:8080/actuator/health"]
ENTRYPOINT [ "/app" ]
```

In case you were wondering, I am not starting from a gradle-based image here, but rather use GraalVM. The GraalVM image provides the necessary tools for the `nativeCompile` task to do its work. However, our application won't "just" work with this `Dockerfile`. One also has to add the `id 'org.graalvm.buildtools.native' version '0.10.6'` plugin to `build.gradle`. In addition to that, one has to slightly modify the arguments passed to the compile command:

```groovy
graalvmNative {
    binaries {
        main {
            buildArgs.addAll("--enable-http", "--static", "--libc=musl")
        }
    }
}
```

As much as `musl` is a headache, it is a requirement to being able to use `--static`. Without it, GraalVM can only create [dynamically linked binaries](https://www.graalvm.org/latest/reference-manual/native-image/guides/build-static-executables/). That defeats the purpose of going down this rabbit hole in the first place.

Another interesting observation is that HTTP has to be enabled explicitly. By default, only `file` and `resource` URL protocols are [enabled](https://www.graalvm.org/latest/reference-manual/native-image/dynamic-features/URLProtocols/).

> You might want to limit the amount of resources passed to `docker build` via `--memory`. GraalVM will max at 75% of the available memory, which can significantly slow down your machine. You would also have to consider the trade-offs of slower build times
{: .prompt-warning}

## UPX

I could have stopped at GraalVM native images, but the result wouldn't be minimalistic if there still was some juice left to squeeze out of the image 😜!

```Dockerfile
FROM container-registry.oracle.com/graalvm/native-image:21-muslib AS builder
WORKDIR /workspace

ARG UPX_VERSION=4.2.2
ARG UPX_ARCHIVE=upx-${UPX_VERSION}-amd64_linux.tar.xz
RUN microdnf -y install wget xz unzip zip findutils && \
    wget -q https://github.com/upx/upx/releases/download/v${UPX_VERSION}/${UPX_ARCHIVE} && \
    tar -xJf ${UPX_ARCHIVE} && \
    rm -rf ${UPX_ARCHIVE} && \
    mv upx-${UPX_VERSION}-amd64_linux/upx . && \
    rm -rf upx-${UPX_VERSION}-amd64_linux && \
    wget -O grandel.zip https://services.gradle.org/distributions/gradle-8.14-bin.zip && \
    unzip grandel.zip -d /opt

COPY . .

ENV GRADLE_HOME="/opt/gradle-8.14"
ENV PATH="$GRADLE_HOME/bin:$PATH"
RUN gradle clean nativeCompile
RUN ./upx --best -o app.upx /workspace/build/native/nativeCompile/htmx

FROM gcr.io/distroless/static-debian12:debug
COPY --from=builder /workspace/app.upx /app

HEALTHCHECK --interval=5s --timeout=15s --start-period=2s --retries=20 CMD ["wget", "-q", "--spider", "http://localhost:8080/actuator/health"]
ENTRYPOINT [ "/app" ]
```

As you can see, most of the structure is the same as the [native](#native) image. The most notable differences are related to `upx`!

## Evaluation

In this section, I will delve into the different aspects considered during benchmarking the methods from above. You can find an overview in the table below:

<div class="datatable-begin"></div>

| Img         | Build Time (s) | Img Size (MB) | Startup Time (s) | Container Mem (MB) | App Mem (MB) |
| ----------- | -------------- | ------------- | ---------------- | ------------------ | ------------ |
| naive       | 1.38           | 823           | 36               | 993.2              | 178.77       |
| multi-stage | 29.17          | 418           | 11               | 323.5              | 280.10       |
| custom-jre  | 42.93          | 168           | 10               | 228                | 261.04       |
| native      | 331.62         | 107           | 5.1              | 26.74              | 90.68        |
| upx         | 412.38         | 39            | 5.1              | 126.7              | 127.40       |

<div class="datatable-end"></div>

The startup time was measured as the time it took the container to report a healthy status. The container memory usage is what docker reports in its stats. The app memory is the RSS memory consumed by the process running inside the container itself.

Most notably, putting more effort in building the image leads to a smaller image size, faster startup time as well as more sustainable memory consumption. A peculiar observation is that the uncompressed native image actually consumes less memory than its compressed counterpart. This is a [known behavior](https://usrme.xyz/posts/using-upx-for-compression-might-work-against-you/) with `upx`. The [rationale](https://github.com/upx/upx/issues/466#issuecomment-789758970) is that the compressed binary will have to get uncompressed in memory during runtime. Luckily, the impact of this behavior isn't that large, since I don't expect to run multiple servers in the same container. Nonetheless, it ought not to be neglected.

The references also mention a toll on the startup time, but my measurements do not reflect it. This could be a mistake in measurement or just not enough profiling on my end.

### Considerations

While trying to build on top of the native image, I encountered incredible difficulties even adding something like [spotbugs](https://github.com/spotbugs), or [checkstyle](https://checkstyle.org/). Those tools rely on a specific class path layout. Thus, getting them to play nicely with GraalVM isn't straight-forward.

Furthermore, dependencies will have to be loaded as `compileOnly`, when lazy-loading them with `runtimeOnly` would have been the "normal" recommended option. This could have unforeseen consequences depending on the library.

## Conclusion

This was an insightful endeavor! I managed to automate building my custom JRE and also getting GraalVM to work! Future works in this field can focus on refining and quantifying the impact of `upx`. In addition, being able to add tools essential for CI/CD pipelines in those images would be an added benefit. The benefits brought upon by GraalVM binaries could make managing Java applications easier, if only the development experience wouldn't suffer.
