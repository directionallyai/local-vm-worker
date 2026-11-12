#!/bin/sh
# Builds the riscv64 worker runtime directory (python-build-standalone + the worker's locked packages + worker.py,
# storage.py) and session_master_local, all cross-compiled; nothing riscv64 is executed. Run inside the `rt-build` stage.
# Inputs: /pbs/python (verified riscv64 PBS tree), /hostpy/python (verified x86_64 PBS, same 3.12.16: bytecode + build venv), /src/wpr (worker-python-runtime checkout), /src/aci (aci-worker checkout), /src/local/warm_server.py (this repo).
# Outputs: /out/runtime, /out/session_master_local, /out/warm_server.py
set -eu
RUST_TARGET=riscv64gc-unknown-linux-gnu
SYSROOT=/sysroot
PBS=/pbs/python
OUT=/out
mkdir -p "$OUT/wheels"
. "$HOME/.cargo/env"

# riscv64 headers and static libs: unpack the debs, do not install them.
mkdir -p "$SYSROOT" /tmp/rvdebs && cd /tmp/rvdebs
retry apt-get download libssl-dev:riscv64 libffi-dev:riscv64 >/dev/null
for d in *.deb; do dpkg-deb -x "$d" "$SYSROOT"; done
LIBDIR=$SYSROOT/usr/lib/riscv64-linux-gnu
rm -f "$LIBDIR"/libssl.so* "$LIBDIR"/libcrypto.so* "$LIBDIR"/libffi.so*

cd /src/wpr
uv export --project . --frozen --no-hashes --no-emit-project -o /tmp/requirements.txt >/dev/null
grep -E '^(cffi|cryptography)==' /tmp/requirements.txt | sed 's/ *;.*//' > /tmp/native.txt
grep -vE '^(cffi|cryptography)==' /tmp/requirements.txt > /tmp/pure.txt

uv venv -q /tmp/venv --python /hostpy/python/bin/python3.12
uv pip install -q --python /tmp/venv/bin/python pip setuptools wheel 'maturin>=1,<2' 'cffi>=2' build
export PATH=/tmp/venv/bin:$PATH
export CC=riscv64-linux-gnu-gcc LDSHARED="riscv64-linux-gnu-gcc -shared" AR=riscv64-linux-gnu-ar
export _PYTHON_HOST_PLATFORM=linux-riscv64 SETUPTOOLS_EXT_SUFFIX=.cpython-312-riscv64-linux-gnu.so
export CFLAGS="-I$PBS/include/python3.12 -I$SYSROOT/usr/include -I$SYSROOT/usr/include/riscv64-linux-gnu"
export LDFLAGS="-L$LIBDIR"
export PKG_CONFIG_LIBDIR="$LIBDIR/pkgconfig:$SYSROOT/usr/share/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

# Native wheels are built from the locked sdists, unpacked at a FIXED path: pip builds a local directory in place, so
# no random temp directory ends up in the binaries (it did, and made the Rust extension differ between builds).
uv export --project /src/wpr --frozen --no-emit-project -o /tmp/req-hashes.txt >/dev/null
mkdir -p /build/dl /build/src
for spec in $(cat /tmp/native.txt); do
  name=${spec%%==*}
  pip download -q --no-deps --no-build-isolation --no-binary :all: -d /build/dl "$spec"
  f=$(ls /build/dl/${name}-*.tar.gz)
  h=$(sha256sum "$f" | cut -d' ' -f1)
  grep -q "sha256:$h" /tmp/req-hashes.txt || { echo "sdist $f ($h) is not in the lock"; exit 1; }
  mkdir -p "/build/src/$name" && tar -xzf "$f" -C "/build/src/$name" --strip-components=1
done

pip wheel -q --no-deps --no-build-isolation -w "$OUT/wheels" /build/src/cffi

(
  export CARGO_BUILD_TARGET="$RUST_TARGET" CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER=riscv64-linux-gnu-gcc
  export CC_riscv64gc_unknown_linux_gnu=riscv64-linux-gnu-gcc AR_riscv64gc_unknown_linux_gnu=riscv64-linux-gnu-ar
  export CFLAGS_riscv64gc_unknown_linux_gnu="$CFLAGS"
  export OPENSSL_DIR="$SYSROOT/usr" OPENSSL_LIB_DIR="$LIBDIR" OPENSSL_INCLUDE_DIR="$SYSROOT/usr/include" OPENSSL_STATIC=1
  export PYO3_CROSS_LIB_DIR="$PBS/lib" PYO3_CROSS_PYTHON_VERSION=3.12 PYO3_CROSS_PYTHON_IMPLEMENTATION=CPython
  export MATURIN_PEP517_ARGS="--target $RUST_TARGET --compatibility off"
  # No build-host paths in the binary.
  export CARGO_INCREMENTAL=0 RUSTFLAGS="--remap-path-prefix=/build/src=/src --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rustup"
  pip wheel -q --no-deps --no-build-isolation -w "$OUT/wheels" /build/src/cryptography
)

# Assemble the runtime directory (as worker-python-runtime's Dockerfile does; .pyc kept, the guest is slow).
R=$OUT/runtime; SP=$R/lib/python3.12/site-packages
rm -rf "$R" && cp -a "$PBS" "$R"
uv pip install -q --no-deps --only-binary :all: --python-version 3.12 --python-platform riscv64-unknown-linux \
  --target "$SP" -r /tmp/pure.txt
for w in "$OUT"/wheels/*.whl; do unzip -q -o "$w" -d "$SP"; done
find "$R" -name '*.dist-info' -prune -exec rm -rf {} +
rm -rf "$SP"/pip* "$R"/lib/python3.12/idlelib "$R"/lib/python3.12/lib2to3 "$R"/lib/python3.12/ensurepip \
  "$R"/lib/python3.12/tkinter "$R"/lib/python3.12/test "$R"/lib/tcl9* "$R"/lib/tk9.0 "$R"/lib/itcl* "$R"/lib/thread* \
  "$R"/lib/libtcl9* "$R"/share "$R"/include "$R"/bin/idle3* "$R"/bin/2to3*
rm -f "$R"/lib/python3.12/lib-dynload/_tkinter*
install -m 0644 /src/wpr/worker.py /src/wpr/storage.py "$SP"/
printf '%s\n' '#!/bin/sh' 'set -e' 'here="$(cd "$(dirname "$0")" && pwd)"' \
  'exec "$here/bin/python3.12" -c "import worker; worker.main()"' > "$R/runtime"
chmod 0755 "$R/runtime"
install -m 0755 /src/local/warm_server.py "$R"/warm_server.py
# Byte-compile with the build host's python (same 3.12 bytecode); unchecked-hash so mtimes do not matter.
/hostpy/python/bin/python3.12 -m compileall -q -j 0 --invalidation-mode unchecked-hash "$R/lib/python3.12"

# session_master_local
cd /src/aci
CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER=riscv64-linux-gnu-gcc \
  cargo build --locked --release --target "$RUST_TARGET" --features unattested-local --bin session_master_local
install -m 0755 "target/$RUST_TARGET/release/session_master_local" "$OUT/session_master_local"
