# syntax=docker/dockerfile:1.7
#
# The firmware and kernel for the local RISC-V guest (RVVM): OpenSBI `fw_jump.bin` and a Linux `Image`.
# Everything is pinned: the base image by digest, apt by snapshot.ubuntu.com timestamp, the kernel by sha256, OpenSBI by
# tag and commit. Nothing riscv64 is executed: both are cross-compiled on amd64/arm64.
#
#   docker buildx build --target artifacts --output type=local,dest=out .
#
# The rootfs (worker only, erofs) is the `rootfs` target; see rootfs/.

ARG UBUNTU_IMAGE=ubuntu@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
ARG SNAPSHOT=20261104T000000Z
ARG SOURCE_DATE_EPOCH=1788613323
ARG CA_CERTIFICATES_DEB=ca-certificates_20260816ubuntu0.24.04.1_all.deb
ARG CA_CERTIFICATES_SHA256=8a0a754aaafed72cc8efb8c1731808133284a84fbfc76a4fcc73fce9e01b4187

# One Ubuntu 24.04 base for everything: the image is pinned by digest and apt reads a snapshot.ubuntu.com timestamp for
# both amd64 (the cross toolchain) and riscv64 (the guest userland), so versions cannot drift or disappear.
FROM ${UBUNTU_IMAGE} AS ubuntu
ARG SNAPSHOT
ARG CA_CERTIFICATES_DEB
ARG CA_CERTIFICATES_SHA256
# The base image has no CA certificates, so apt could not verify TLS to the snapshot. BuildKit fetches the
# ca-certificates .deb itself and checks it against a pinned sha256; a bundle is built from the unpacked package and
# apt then installs the real package over it. TLS is verified on every fetch.
ADD --checksum=sha256:${CA_CERTIFICATES_SHA256} https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT}/pool/main/c/ca-certificates/${CA_CERTIFICATES_DEB} /tmp/ca-certificates.deb
RUN dpkg-deb -x /tmp/ca-certificates.deb /tmp/ca && mkdir -p /etc/ssl/certs \
 && cat /tmp/ca/usr/share/ca-certificates/mozilla/*.crt > /etc/ssl/certs/ca-certificates.crt && rm -rf /tmp/ca /tmp/ca-certificates.deb \
 && rm -f /etc/apt/sources.list /etc/apt/sources.list.d/* \
 && for arch in amd64 riscv64; do \
      printf 'Types: deb\nURIs: https://snapshot.ubuntu.com/ubuntu/%s\nSuites: noble noble-updates noble-security\nComponents: main universe\nArchitectures: %s\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n\n' "$SNAPSHOT" "$arch"; \
    done > /etc/apt/sources.list.d/snapshot.sources \
 && printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "10";\n' > /etc/apt/apt.conf.d/10snapshot \
 && dpkg --add-architecture riscv64 \
 && printf '#!/bin/sh\n# retry a command: snapshot.ubuntu.com intermittently answers 5xx\nn=0; until "$@"; do n=$((n+1)); [ "$n" -ge 8 ] && exit 1; echo "attempt $n failed, retrying in 30s: $*" >&2; sleep 30; done\n' > /usr/local/bin/retry \
 && chmod +x /usr/local/bin/retry \
 && retry sh -c 'apt-get update -qq -o APT::Update::Error-Mode=any && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null' \
 && rm -rf /var/lib/apt/lists/*

FROM ubuntu AS toolchain
RUN retry sh -c 'apt-get update -qq -o APT::Update::Error-Mode=any && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      gcc-riscv64-linux-gnu libc6-dev-riscv64-cross gcc make flex bison bc libssl-dev libelf-dev cpio xz-utils \
      ca-certificates curl git perl python3 kmod rsync >/dev/null'

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

# ---------------------------------------------------------------------------------------------------------------
# Rootfs: the worker runtime for riscv64, on Ubuntu 24.04 (noble) with everything from one snapshot.ubuntu.com
# timestamp: the cross toolchain and its glibc headers (amd64) and the guest's riscv64 userland come from the same
# archive state, so versions cannot drift apart or disappear between builds.
# ---------------------------------------------------------------------------------------------------------------

FROM ubuntu AS rt-build
ARG UV_VERSION=0.12.15
ARG UV_SHA256=f97935763c04be3e692460a7aaeaaab8fc3b78fcf8b389da820b38ae7423a638
ARG RUSTUP_VERSION=1.28.2
ARG RUSTUP_SHA256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
ARG RUST_VERSION=1.93.1
ARG PBS_RELEASE=20261026
ARG PBS_PYTHON=3.12.16
ARG PBS_RISCV64_SHA256=4090e42b060cc5dadfa8ba26556efff4db841dce05cecb1b3645a17d1a93ae4e
ARG PBS_X86_64_SHA256=ce4f6d0a6cfdb3bed6e44c2f9affd85943c76a42e25ad3a259002f31d6fb8a20
ARG ACI_WORKER_COMMIT=bc045fce69ea5ae62be0343bfb5a6e134e62477e
ARG WORKER_PYTHON_RUNTIME_COMMIT=58d417559069e7a7a804529e522bbeb6c2d065a2
ARG SOURCE_DATE_EPOCH
RUN retry sh -c 'apt-get update -qq -o APT::Update::Error-Mode=any && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      ca-certificates curl git unzip pkg-config build-essential gcc-riscv64-linux-gnu libc6-dev-riscv64-cross >/dev/null'
RUN curl -fsSL -o /tmp/uv.tgz "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
 && echo "${UV_SHA256}  /tmp/uv.tgz" | sha256sum -c - \
 && tar -C /tmp -xzf /tmp/uv.tgz && install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv
RUN curl -fsSL -o /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init" \
 && echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c - && chmod +x /tmp/rustup-init \
 && /tmp/rustup-init -y --profile minimal --default-toolchain "${RUST_VERSION}" --target riscv64gc-unknown-linux-gnu >/dev/null 2>&1
RUN B="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/cpython-${PBS_PYTHON}+${PBS_RELEASE}" \
 && mkdir -p /pbs /hostpy \
 && curl -fsSL -o /tmp/rv.tgz "${B}-riscv64-unknown-linux-gnu-install_only_stripped.tar.gz" \
 && echo "${PBS_RISCV64_SHA256}  /tmp/rv.tgz" | sha256sum -c - && tar -C /pbs -xzf /tmp/rv.tgz \
 && curl -fsSL -o /tmp/x86.tgz "${B}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" \
 && echo "${PBS_X86_64_SHA256}  /tmp/x86.tgz" | sha256sum -c - && tar -C /hostpy -xzf /tmp/x86.tgz
RUN git init -q /src/aci && git -C /src/aci fetch -q --depth 1 https://github.com/directionallyai/aci-worker "${ACI_WORKER_COMMIT}" \
 && git -C /src/aci checkout -q FETCH_HEAD \
 && git init -q /src/wpr && git -C /src/wpr fetch -q --depth 1 https://github.com/directionallyai/worker-python-runtime "${WORKER_PYTHON_RUNTIME_COMMIT}" \
 && git -C /src/wpr checkout -q FETCH_HEAD
COPY local/warm_server.py /src/local/warm_server.py
COPY rootfs/build-runtime.sh /build-runtime.sh
RUN /build-runtime.sh

FROM scratch AS rt-export
COPY --from=rt-build /out /

FROM ubuntu AS rootfs-tree
ARG SOURCE_DATE_EPOCH
RUN retry sh -c 'apt-get update -qq -o APT::Update::Error-Mode=any && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends erofs-utils xz-utils >/dev/null'
# riscv64 userland: unpacked, never run. busybox-static for the init script; libc6/libgcc-s1 for the two dynamic
# binaries; ca-certificates for the guest's TLS to storage.
RUN mkdir -p /debs /root-tree && cd /debs \
 && retry apt-get download libc6:riscv64 libgcc-s1:riscv64 gcc-14-base:riscv64 busybox-static:riscv64 ca-certificates >/dev/null \
 && for d in *.deb; do dpkg-deb -x "$d" /root-tree; done \
 && ls /debs > /debs.txt
RUN cd /root-tree \
 && for d in bin sbin lib; do if [ -d $d ] && [ ! -L $d ]; then mkdir -p usr/$d && cp -a $d/. usr/$d/ && rm -rf $d; fi; [ -e $d ] || ln -s usr/$d $d; done \
 && mkdir -p proc sys dev run tmp root etc/ssl/certs opt/bin \
 && : > etc/resolv.conf \
 && printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' > etc/passwd \
 && printf 'root:x:0:\nnogroup:x:65534:\n' > etc/group \
 && cat usr/share/ca-certificates/mozilla/*.crt > etc/ssl/certs/ca-certificates.crt \
 && ln -s ca-certificates.crt etc/ssl/certs/ca-bundle.crt && ln -s certs/ca-certificates.crt etc/ssl/cert.pem \
 && for a in sh sed cut tr cat ls mkdir ln sleep mount date touch echo ip kill ps; do ln -sf busybox usr/bin/$a; done
COPY guest/rvvm-init /root-tree/usr/sbin/rvvm-init
COPY --from=rt-build /out/runtime /root-tree/opt/worker-runtime
COPY --from=rt-build /out/session_master_local /root-tree/opt/bin/session_master_local
RUN chmod 0755 /root-tree/usr/sbin/rvvm-init \
 && find /root-tree -newermt "@${SOURCE_DATE_EPOCH}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} + \
 && mkdir -p /out && cd /out \
 && mkfs.erofs -T "${SOURCE_DATE_EPOCH}" -U 00000000-0000-0000-0000-000000000000 --all-root /out/rootfs.erofs /root-tree \
 && xz -9e -k --threads=1 /out/rootfs.erofs \
 && cp /debs.txt /out/debs.txt

FROM scratch AS rootfs
COPY --from=rootfs-tree /out/rootfs.erofs /rootfs.erofs
COPY --from=rootfs-tree /out/rootfs.erofs.xz /rootfs.erofs.xz
COPY --from=rootfs-tree /out/debs.txt /debs.txt
