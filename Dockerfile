# syntax=docker/dockerfile:1.7
#
# The firmware and kernel for the local RISC-V guest (RVVM): OpenSBI `fw_jump.bin` and a Linux `Image`.
# Everything is pinned: the base image by digest, apt by snapshot.debian.org timestamp, the kernel by sha256, OpenSBI by
# tag and commit. Nothing riscv64 is executed: both are cross-compiled on amd64/arm64.
#
#   docker buildx build --target artifacts --output type=local,dest=out .
#
# The rootfs is a separate target (see rootfs/), added after these two.

ARG DEBIAN_IMAGE=debian@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6
ARG SNAPSHOT=20261104T212339Z
ARG SOURCE_DATE_EPOCH=1788613323

FROM ${DEBIAN_IMAGE} AS toolchain
ARG SNAPSHOT
RUN printf 'Types: deb\nURIs: http://snapshot.debian.org/archive/debian/%s\nSuites: trixie trixie-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n\nTypes: deb\nURIs: http://snapshot.debian.org/archive/debian-security/%s\nSuites: trixie-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n' "$SNAPSHOT" "$SNAPSHOT" > /etc/apt/sources.list.d/debian.sources \
 && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/10snapshot \
 && apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      gcc-riscv64-linux-gnu libc6-dev-riscv64-cross gcc make flex bison bc libssl-dev libelf-dev cpio xz-utils \
      ca-certificates curl git perl python3 kmod rsync >/dev/null

FROM toolchain AS opensbi
ARG OPENSBI_TAG=v1.7
ARG OPENSBI_COMMIT=a32a91069119e7a5aa31e6bc51d5e00860be3d80
ARG SOURCE_DATE_EPOCH
RUN git clone -q --depth 1 --branch "$OPENSBI_TAG" https://github.com/riscv-software-src/opensbi /opensbi \
 && test "$(git -C /opensbi rev-parse HEAD)" = "$OPENSBI_COMMIT" \
 && make -s -C /opensbi -j"$(nproc)" CROSS_COMPILE=riscv64-linux-gnu- PLATFORM=generic \
 && cp /opensbi/build/platform/generic/firmware/fw_jump.bin /fw_jump.bin

FROM toolchain AS kernel
ARG KERNEL_VERSION=6.18.56
ARG KERNEL_SHA256=4633bbda2ab95eaf2a7af4041236451d6759c72e6946265531af4b3aacefbf89
ARG SOURCE_DATE_EPOCH
RUN curl -fsSL -o /linux.tar.xz "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz" \
 && echo "${KERNEL_SHA256}  /linux.tar.xz" | sha256sum -c - \
 && mkdir /linux && tar -xf /linux.tar.xz -C /linux --strip-components=1
COPY kernel/rvvm.config /linux/.config
# Same build host / user / time every run, so the image does not carry ours.
ENV KBUILD_BUILD_HOST=local-vm-worker KBUILD_BUILD_USER=build KBUILD_BUILD_TIMESTAMP="2026-09-06 00:00:00 UTC"
RUN cd /linux && make -s ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig \
 && make -s ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)" Image \
 && cp arch/riscv/boot/Image /Image && cp .config /kernel.config

FROM scratch AS artifacts
COPY --from=opensbi /fw_jump.bin /fw_jump.bin
COPY --from=kernel /Image /Image
COPY --from=kernel /kernel.config /kernel.config
