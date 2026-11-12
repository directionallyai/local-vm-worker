# local-vm-worker

Build inputs for running the Directionally worker in a local RISC-V guest ([RVVM](https://github.com/directionallyai/RVVM))
instead of a TEE. Dev use only: nothing here is attested.

What is built here, all with pinned inputs and no riscv64 code executed at build time:

| Output | Source |
|---|---|
| `fw_jump.bin` | OpenSBI v1.7 (tag and commit pinned in `Dockerfile`) |
| `Image` | Linux 6.18.56 from kernel.org (sha256 pinned), config in `kernel/rvvm.config` |
| `rootfs.erofs` | not yet: see "Status" |

```
docker buildx build --target artifacts --output type=local,dest=out .
```

The base is Ubuntu 24.04, pinned by image digest, and apt reads `snapshot.ubuntu.com` at a fixed timestamp for both amd64 (the cross toolchain) and riscv64 (the guest userland), so the toolchain does not move. The rootfs (`--target rootfs`: worker-only erofs plus `.xz`) is built from pinned inputs and checked for byte-for-byte reproducibility in CI.
CI (`.github/workflows/build.yml`) builds twice and fails if the results differ.

## Status

- Firmware and kernel: Dockerfile and CI written.
- Rootfs: not built here yet. Today it is assembled by hand from the Cartesi Ubuntu base, a cross-built uv/CPython runtime,
  `worker.py`/`storage.py`, `warm_server.py` (aci-worker) and `session_master_local`. The recipes are in aci-worker
  `local/cartesi/`.
- `kernel/rvvm.config` comes from a Cartesi 6.18.56 tree (a patched kernel) and is applied to the mainline tarball with
  `olddefconfig`, which drops the Cartesi-only options. Whether a mainline build boots the full rootfs is checked by the
  boot test, not assumed.

`guest/rvvm-init` is the guest's init: it configures the network (192.168.0.100 behind RVVM's gateway) and starts the worker.
