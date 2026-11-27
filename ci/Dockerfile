# flightvis-client CI image — build/publish on omarchibald (Infra)
#
#   docker build -t registry.heavenly.cl/flightvis/flutter-android-ci:3.50.0-ndk28.2.13676358 ci/
#   docker push registry.heavenly.cl/flightvis/flutter-android-ci:3.50.0-ndk28.2.13676358
#
# Pre-pull on agent before first pipeline (image is large; omarchibald disk is tight):
#   docker pull registry.heavenly.cl/flightvis/flutter-android-ci:3.50.0-ndk28.2.13676358
#
# Pins: Flutter 3.50.0, Android platform 37, NDK 28.2.13676358 (android/app/build.gradle.kts).

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUTTER_VERSION=3.50.0
ARG ANDROID_SDK_ROOT=/opt/android-sdk
ARG NDK_VERSION=28.2.13676358
ARG CMDLINE_TOOLS_REV=13114758

ENV ANDROID_HOME=${ANDROID_SDK_ROOT} \
    ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT} \
    FLUTTER_ROOT=/opt/flutter \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:/usr/lib/jvm/java-17-openjdk-amd64/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    openjdk-17-jdk-headless \
    unzip \
    xz-utils \
    zip \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/flutter/flutter.git -b ${FLUTTER_VERSION} --depth 1 /opt/flutter \
    && flutter --version \
    && flutter config --no-analytics \
    && flutter precache --android

RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools \
    && curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_REV}_latest.zip" -o /tmp/cmdline-tools.zip \
    && unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools \
    && mv /tmp/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
    && rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools

RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager --install \
        "platform-tools" \
        "platforms;android-37" \
        "build-tools;36.0.0" \
        "ndk;${NDK_VERSION}"

WORKDIR /woodpecker/src

LABEL org.opencontainers.image.title="flightvis-flutter-android-ci" \
      org.opencontainers.image.description="Flutter ${FLUTTER_VERSION} + Android SDK 37 + NDK ${NDK_VERSION} for flightvis-client Woodpecker pipelines" \
      org.heavenly.flightvis.flutter-version="${FLUTTER_VERSION}" \
      org.heavenly.flightvis.ndk-version="${NDK_VERSION}"