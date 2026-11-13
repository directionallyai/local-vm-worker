#!/usr/bin/env python3
"""Print manifest.json for the carrier directory given as argv[1].

The format is what local_vm.download_image takes, minus the URL: for each file its sha256 and size; for the rootfs,
which ships compressed, the sha256/size of the .xz and of what it unpacks to (taken from rootfs.erofs, which the caller
removes afterwards). The guest files are riscv64 and the same for every host; the emulator is not, so `rvvm` is a table
keyed by host ("linux-x86_64", "macos-arm64", "windows-x86_64", ...), one entry per `rvvm-<host>[.exe]` file present.
`tested` lists the hosts someone has booted the guest on; the client refuses the others. Sorted and compact so the same
inputs always give the same bytes."""
import hashlib
import json
import os
import sys


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


root = sys.argv[1]
files = {}
TESTED = {"linux-x86_64"}
hosts = {}
for entry in sorted(os.listdir(root)):
    if entry.startswith("rvvm-"):
        host = entry[len("rvvm-"):].removesuffix(".exe")
        p = os.path.join(root, entry)
        hosts[host] = {"file": entry, "sha256": digest(p), "size": os.path.getsize(p), "tested": host in TESTED}
if not hosts:
    sys.exit("no rvvm-<host> file in " + root)
for name in ("fw_jump.bin", "Image"):
    p = os.path.join(root, name)
    files[name] = {"sha256": digest(p), "size": os.path.getsize(p)}
xz, raw = os.path.join(root, "rootfs.erofs.xz"), os.path.join(root, "rootfs.erofs")
files["rootfs.erofs"] = {
    "file": "rootfs.erofs.xz",
    "sha256": digest(xz),
    "size": os.path.getsize(xz),
    "compression": "xz",
    "sha256_out": digest(raw),
    "size_out": os.path.getsize(raw),
}
print(json.dumps({"version": 2, "files": files, "rvvm": hosts}, sort_keys=True, separators=(",", ":")))
