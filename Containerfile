# Pinned builder image for QOS. The goal is reproducibility of the build
# *environment*, not of the artifact yet — byte-identical artifacts come
# later (step 9 in docs/FEATURE-REVIEW-AND-IDEAS.md).
#
# Pin the digest (not just the tag) once the first build succeeds:
#   podman inspect --format '{{.Digest}}' alpine:3.23
# Then replace alpine:3.23 below with alpine@sha256:...

FROM docker.io/library/alpine:edge

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apk add --no-cache \
    bash \
    coreutils \
    findutils \
    util-linux \
    grep \
    sed \
    gawk \
    diffutils \
    file \
    tar \
    xz \
    cpio \
    gzip \
    zstd \
    jq \
    python3 \
    py3-yaml \
    git \
    make \
    curl \
    ca-certificates \
    openssl \
    dosfstools \
    e2fsprogs \
    e2fsprogs-extra \
    sgdisk \
    mtools \
    xorriso \
    squashfs-tools \
    indent \
    help2man \
    busybox-extras \
    bc \
    perl \
    flex \
    bison \
    elfutils-dev \
    openssl-dev \
    linux-headers \
    musl-dev \
    gcc \
    g++ \
    libc-dev \
    binutils

WORKDIR /work
