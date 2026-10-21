#!/usr/bin/env python3
"""校验 AnyKernel3 zip 里的内核是否真的编入了 droidspaces 需要的功能。

用法:
    python check_ds_support.py APTKernel_MIUI_pipa_....zip

原理（为什么不能看 /proc/config.gz）:
    这类内核内嵌的 IKCONFIG 与实物不符（CONFIG_LOCALVERSION 都对不上实际版本），
    会声称 PID_NS/SYSVIPC/DEVTMPFS 全是 not set，而实际镜像里这些功能是在的。
    所以这里直接在内核二进制里找“只有编进去才会存在的字符串”：
      - CONFIG_DEVTMPFS  -> "devtmpfs: initialized"
      - CONFIG_PID_NS    -> "pid_for_children"
      - CONFIG_SYSVIPC   -> "sysvipc"
    （IPC_NS 跟随 SYSVIPC 自动打开，见 init/Kconfig:
       config IPC_NS  depends on (SYSVIPC || POSIX_MQUEUE)）
"""
import gzip
import io
import re
import sys
import zipfile

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

MARKERS = {
    "CONFIG_DEVTMPFS": b"devtmpfs: initialized",
    "CONFIG_PID_NS": b"pid_for_children",
    "CONFIG_SYSVIPC": b"sysvipc",
}


def iter_images(zf, prefix=""):
    """支持一层嵌套（外层 zip 里套内层 anykernel zip）。"""
    for name in zf.namelist():
        if name.endswith("/"):
            continue
        if name.lower().endswith(".zip"):
            with zipfile.ZipFile(io.BytesIO(zf.read(name))) as inner:
                for item in iter_images(inner, prefix + name + " :: "):
                    yield item
        elif re.search(r"(^|/)Image(\.gz)?$", name):
            yield prefix + name, zf.read(name)


def check(zip_path):
    print("=" * 74)
    print(zip_path)
    with zipfile.ZipFile(zip_path) as zf:
        entries = [n for n in zf.namelist() if not n.endswith("/")]
        print("  entries:", ", ".join(entries[:12]) + (" ..." if len(entries) > 12 else ""))
        kernels = list(iter_images(zf))
        dtbo = [n for n in zf.namelist() if n.lower().endswith("dtbo.img")]

    if not kernels:
        print("  [FAIL] 没找到 Image（这个 zip 不是 AnyKernel3 内核包？）")
        return False

    ok = True
    for name, blob in kernels:
        if name.endswith(".gz"):
            blob = gzip.decompress(blob)
        print("-" * 74)
        print("  kernel : %s  (%.1f MB)" % (name, len(blob) / 1048576))
        m = re.search(rb"Linux version [^\x00]{0,120}", blob)
        print("  version:", m.group(0).decode("utf-8", "replace") if m else "(not found)")
        for label, needle in MARKERS.items():
            hit = blob.count(needle)
            print("  [%s] %-20s %-26s hits=%d"
                  % ("OK  " if hit else "FAIL", label, needle.decode(), hit))
            ok = ok and hit > 0
        for tag in (b"ReSukiSU", b"KernelSU", b"susfs"):
            print("         %-20s hits=%d" % (tag.decode(), blob.count(tag)))

    print("-" * 74)
    print("  dtbo.img in zip:", dtbo if dtbo else "没有（推荐：保留原厂 dtbo）")
    print("  结论:", "PASS - 可以跑 droidspaces" if ok else "FAIL - 缺容器能力，别刷")
    return ok


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    results = [check(p) for p in sys.argv[1:]]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
