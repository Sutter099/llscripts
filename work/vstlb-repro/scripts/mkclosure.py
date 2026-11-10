#!/usr/bin/env python3
"""Copy the shared-library closure of riscv64 ELF seeds into ROOT (from SYS)."""
import os, re, shutil, subprocess, sys

SYS = os.environ.get("SYS", "/tmp/kvmci/sysroot")
ROOT = os.environ.get("ROOT")
seeds = sys.argv[1:]
if not ROOT or not seeds:
    sys.exit("usage: SYS=<sysroot> ROOT=<rootfs> mkclosure.py <elf> [elf...]")

index = {}
for dp, _, fs in os.walk(SYS):
    for f in fs:
        index.setdefault(f, []).append(os.path.join(dp, f))


def pick(name):
    c = index.get(name) or []
    for p in c:
        if "riscv64-linux-gnu" in p:
            return p
    return c[0] if c else None


def elf(p):
    dyn = subprocess.run(["readelf", "-d", p], capture_output=True, text=True).stdout
    lin = subprocess.run(["readelf", "-l", p], capture_output=True, text=True).stdout
    need = re.findall(r"\(NEEDED\).*\[([^\]]+)\]", dyn)
    m = re.search(r"Requesting program interpreter: ([^\]]+)", lin)
    return need, (m.group(1) if m else None)


copied, missing = set(), set()


def interp_src(interp):
    base = interp.lstrip("/")
    for c in (os.path.join(SYS, base), os.path.join(SYS, "usr", base)):
        if os.path.exists(c):
            return c
    return pick(os.path.basename(base))


def add_interp(interp):
    src = interp_src(interp)
    if not src:
        missing.add(os.path.basename(interp))
        return
    dst = os.path.join(ROOT, interp.lstrip("/"))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not os.path.exists(dst):
        shutil.copy2(src, dst)
        os.chmod(dst, 0o755)


def add(path):
    rel = os.path.relpath(path, SYS)
    if rel in copied:
        return
    dst = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not os.path.exists(dst):
        shutil.copy2(path, dst)
        os.chmod(dst, 0o755 if os.access(path, os.X_OK) else 0o644)
    copied.add(rel)
    need, interp = elf(path)
    if interp:
        add_interp(interp)
    for n in need:
        p = pick(n)
        if p:
            add(p)
        else:
            missing.add(n)


for s in seeds:
    p = os.path.join(ROOT, s.lstrip("/"))
    if not os.path.exists(p):
        print("MISSING SEED", p)
        continue
    need, interp = elf(p)
    for n in need:
        q = pick(n)
        if q:
            add(q)
        else:
            missing.add(n)
    if interp:
        add_interp(interp)

print("libs copied: %d, unresolved: %s" % (len(copied), " ".join(sorted(missing)) or "none"))
