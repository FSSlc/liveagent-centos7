# =============================================================================
# Build the LiveAgent CentOS 7 bundle in a container.
#
# The bundling logic lives in build.sh (shared with local builds and CI), so
# this image and `bash build.sh` produce the same package.
#
#   docker build --build-arg APPIMAGE_URL=https://github.com/Stack-Cairn/LiveAgent/releases/download/vX.Y.Z/LiveAgent-vX.Y.Z-Linux-x86_64.AppImage -t liveagent-centos7 .
#   docker create --name tmp liveagent-centos7
#   docker cp tmp:/output/liveagent-centos7-x86_64.tar.gz .
#   docker rm tmp
#
# Real-desktop verification is a separate image (Dockerfile.desktop) driven by
# verify-desktop.sh.
# =============================================================================

FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Ubuntu 24.04 supplies the glibc 2.39 loader/libc pair that gets bundled.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        curl ca-certificates file patchelf squashfs-tools binutils \
        libwayland-client0 libwayland-cursor0 libwayland-egl1 libwayland-server0 \
        libxkbcommon0 \
        libfribidi0 libharfbuzz0b libfontconfig1 libfreetype6 libexpat1 \
        libdrm2 libxcb1 libx11-6 libx11-xcb1 libgbm1 libegl1 libgl1 \
    && rm -rf /var/lib/apt/lists/*

ARG APPIMAGE_URL
# CONDA_BUILD=1 skips patchelf (conda patches at install time) — used to build
# the bundle that goes into the conda package.
ARG CONDA_BUILD=0

ENV APPIMAGE_URL=${APPIMAGE_URL} \
    CONDA_BUILD=${CONDA_BUILD} \
    WORK_DIR=/tmp/liveagent-build \
    OUTPUT_DIR=/output

COPY build.sh launcher.sh /src/
WORKDIR /src

RUN mkdir -p "${OUTPUT_DIR}" && bash /src/build.sh && \
    ls -lh "${OUTPUT_DIR}/liveagent-centos7-x86_64.tar.gz"

# -----------------------------------------------------------------------------
# Package stage (default target): carries only the artifacts, so
# `docker cp <container>:/output/...` works out of the box.
# -----------------------------------------------------------------------------
FROM ubuntu:24.04 AS package

COPY --from=builder /output /output
CMD ["ls", "-lh", "/output"]
