#!/usr/bin/env python3
"""把 AnyKernel3 zip 里的内核 Image 换进一个 boot 镜像，产出可 fastboot 刷的 boot.img。

用途:
    没有 root、没有 TWRP 时，AnyKernel3 的卡刷包没法用。
    这个脚本保留原厂 ramdisk（只换内核），生成 boot.img 后用:
        fastboot flash boot_a boot_new.img

用法:
    python bootize.py --base boot_dump.img --zip APTKernel_MIUI_pipa_....zip \
        --flavor miui --out boot_new.img

base 从哪里来:
    设备有 root 时 dd 备份的分区镜像，或官方 ROM 包里的 images/boot.img
"""
import argparse
import gzip
import hashlib
import io
import re
import struct
import sys
import zipfile

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

PAGE = 4096
HDR_V3 = 1580
MAGIC = b"ANDROID!"


def sha(b):
    return hashlib.sha256(b).hexdigest()


def split_boot(data):
    if data[:8] != MAGIC:
        sys.exit("base 不是 Android boot 镜像")
    ks, rs, osv, hs = struct.unpack_from("<4I", data, 8)
    reserved = list(struct.unpack_from("<4I", data, 24))
    hv = struct.unpack_from("<I", data, 40)[0]
    cmdline = data[44:44 + 1536]
    if hv != 3:
        sys.exit("只支持 header v3（本机 pipa 就是 v3），当前 v%d" % hv)
    kernel = data[PAGE:PAGE + ks]
    rd_off = (PAGE + ks + PAGE - 1) // PAGE * PAGE
    ramdisk = data[rd_off:rd_off + rs]
    return dict(ks=ks, rs=rs, osv=osv, hv=hv, reserved=reserved,
                cmdline=cmdline, kernel=kernel, ramdisk=ramdisk)


def iter_images(zf, prefix=""):
    """支持一层嵌套（外层 zip 里套内层 anykernel zip）。"""
    for name in zf.namelist():
        if name.endswith("/"):
            continue
        if name.lower().endswith(".zip"):
            with zipfile.ZipFile(io.BytesIO(zf.read(name))) as inner:
                for item in iter_images(inner, prefix + name + " :: "):
                    yield item
        elif re.search(r"(^|/)Image$", name):
            yield prefix + name, zf.read(name)


def pick_image(zf, flavor):
    images = list(iter_images(zf))
    if not images:
        sys.exit("zip 里没有 Image（不是 AnyKernel3 内核包）")
    if flavor:
        pref = [(n, b) for n, b in images if ("/%s/" % flavor) in n]
        if pref:
            images = pref
    images.sort(key=lambda x: len(x[0]))
    return images[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="原厂 boot 分区备份 / ROM 里的 boot.img")
    ap.add_argument("--zip", required=True, help="AnyKernel3 内核 zip")
    ap.add_argument("--flavor", default="miui", help="miui / aosp（HyperOS 用 miui）")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    base = open(a.base, "rb").read()
    b = split_boot(base)
    print("base : %d bytes, kernel=%d, ramdisk=%d, os_version=0x%08x, cmdline=%r"
          % (len(base), b["ks"], b["rs"], b["osv"], b["cmdline"].rstrip(b"\0")))

    with zipfile.ZipFile(a.zip) as zf:
        name, nk = pick_image(zf, a.flavor)
    print("新内核: %s  (%.1f MB)  sha=%s" % (name, len(nk) / 1048576, sha(nk)[:16]))

    raw = gzip.decompress(b["ramdisk"])
    print("ramdisk: gunzip ok, %.1f MB, %d cpio 条目"
          % (len(raw) / 1048576, raw.count(b"070701")))

    hdr = bytearray(MAGIC)
    hdr += struct.pack("<4I", len(nk), len(b["ramdisk"]), b["osv"], HDR_V3)
    hdr += struct.pack("<4I", *b["reserved"])
    hdr += struct.pack("<I", b["hv"])
    hdr += b["cmdline"]
    assert len(hdr) == HDR_V3

    img = bytearray(hdr)
    img += b"\0" * (PAGE - len(img))
    img += nk
    if len(img) % PAGE:
        img += b"\0" * (PAGE - len(img) % PAGE)
    img += b["ramdisk"]
    if len(img) % PAGE:
        img += b"\0" * (PAGE - len(img) % PAGE)

    open(a.out, "wb").write(bytes(img))

    v = open(a.out, "rb").read()
    ks, rs, osv, _ = struct.unpack_from("<4I", v, 8)
    rd = (PAGE + ks + PAGE - 1) // PAGE * PAGE
    print("-" * 60)
    print("输出 : %s  (%.2f MiB)" % (a.out, len(v) / 1048576))
    print("  header v3      :", "OK" if v[:8] == MAGIC and struct.unpack_from("<I", v, 40)[0] == 3 else "FAIL")
    print("  os_version 保留:", "OK" if osv == b["osv"] else "FAIL")
    print("  ramdisk 未改动 :", "OK" if sha(v[rd:rd + rs]) == sha(b["ramdisk"]) else "FAIL")
    print("  内核已替换     :", "OK" if sha(v[PAGE:PAGE + ks]) == sha(nk) else "FAIL")
    print("  大小 4K 对齐   :", "OK" if len(v) % PAGE == 0 else "FAIL")
    print("  sha256         :", sha(v))
    print()
    print("刷入（只写 a 槽，b 槽留作回滚）:")
    print("  fastboot flash boot_a %s" % a.out)
    print("回滚:")
    print("  fastboot flash boot_a <原厂 boot.img>   或   fastboot set_active b")


if __name__ == "__main__":
    main()
