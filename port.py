#!/usr/bin/env python3
"""HyperOS -> OnePlus 9 Pro porter.

The target hardware side (vendor + odm) comes from a OnePlus 9 Pro stock ROM.
The Android/HyperOS side (system + system_ext + product, plus optional mi_ext)
comes from the donor HyperOS ROM.

This intentionally avoids OnePlus 13-specific display/FOD/attestation patches.
Target-specific hardware quirks should be added as overlays under RES/ only
when verified on the OnePlus 9 Pro.
"""

import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import payload_extractor  # noqa: E402
from erofs_config import sync_config  # noqa: E402

TARGET_NAME = "OnePlus 9 Pro"
TARGET_HINTS = ("OnePlus9Pro", "lemonadep", "LE2120", "LE2121", "LE2123", "LE2125")
FROM_STOCK = ("vendor", "odm")
FROM_HYPEROS_REQUIRED = ("system", "system_ext", "product")
FROM_HYPEROS_OPTIONAL = ("mi_ext",)
PACK = ("system", "system_ext", "product", "vendor", "odm")

EROFS_BIN = os.path.join(HERE, "bin", "Linux", "x86_64")
MKFS = os.path.join(EROFS_BIN, "mkfs.erofs")
EXTRACT = os.path.join(EROFS_BIN, "extract.erofs")
FIXES_DIR = os.path.join(HERE, "fixes")


def log(msg):
    print(msg, flush=True)


def die(msg):
    log("ERROR: " + msg)
    raise SystemExit(1)


def run(cmd, quiet=False):
    log("+ " + " ".join(str(x) for x in cmd))
    if quiet:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if p.returncode:
            sys.stdout.write(p.stdout.decode("utf-8", "replace"))
            raise subprocess.CalledProcessError(p.returncode, cmd)
        return
    subprocess.run(cmd, check=True)


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def read_lines(path):
    return read_text(path).splitlines()


def write_lines(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def download(url, dst_dir, label):
    os.makedirs(dst_dir, exist_ok=True)
    clean = url.lower().split("?", 1)[0]
    ext = ".bin" if clean.endswith(".bin") else ".zip"
    out = os.path.join(dst_dir, label + "_download" + ext)
    if shutil.which("aria2c"):
        run(["aria2c", "-c", "-x", "16", "-s", "16", "-o", os.path.basename(out), "-d", dst_dir, url])
    elif shutil.which("curl"):
        run(["curl", "-L", "--fail", "-o", out, url])
    elif shutil.which("wget"):
        run(["wget", "-O", out, url])
    else:
        die("no downloader found (need aria2c, curl or wget)")
    return out


def unzip_input(zip_path, dst_dir, label):
    out = os.path.join(dst_dir, label + "_zip")
    os.makedirs(out, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        payload = next((n for n in names if os.path.basename(n) == "payload.bin"), None)
        if payload:
            z.extract(payload, out)
            return os.path.join(out, payload)
        imgs = [n for n in names if n.lower().endswith(".img")]
        if not imgs:
            die(f"{label} zip has neither payload.bin nor *.img files")
        for n in imgs:
            z.extract(n, out)
        return out


def resolve_input(src, dst_dir, label):
    local = download(src, dst_dir, label) if src.startswith(("http://", "https://")) else src
    if os.path.isdir(local):
        return local
    low = local.lower()
    if low.endswith(".zip"):
        return unzip_input(local, dst_dir, label)
    if os.path.basename(local) == "payload.bin" or low.endswith(".bin"):
        return local
    die(f"cannot handle {label} input: {src}")


def payload_tool():
    tool = shutil.which("payload-dumper-go") or shutil.which("payload_dumper_go")
    bundled = os.path.join(EROFS_BIN, "payload-dumper-go")
    if not tool and os.path.exists(bundled):
        tool = bundled
    return tool


def dump_payload(payload, out_dir, parts):
    os.makedirs(out_dir, exist_ok=True)
    tool = payload_tool()
    if tool:
        run([tool, "-p", ",".join(parts), "-o", out_dir, payload], quiet=True)
    else:
        payload_extractor.extract(payload, out_dir, parts, log=lambda *_: None)


def get_required_images(resolved, out_dir, parts, label):
    if os.path.isdir(resolved):
        found = {p: os.path.join(resolved, p + ".img") for p in parts}
        missing = [p for p, path in found.items() if not os.path.exists(path)]
        if missing:
            die(f"{label} dir missing images: {', '.join(missing)}")
        return found
    dump_payload(resolved, out_dir, parts)
    found = {p: os.path.join(out_dir, p + ".img") for p in parts}
    missing = [p for p, path in found.items() if not os.path.exists(path)]
    if missing:
        die(f"{label} payload missing images: {', '.join(missing)}")
    return found


def get_optional_image(resolved, out_dir, part):
    if os.path.isdir(resolved):
        path = os.path.join(resolved, part + ".img")
        return path if os.path.exists(path) else None
    try:
        dump_payload(resolved, out_dir, (part,))
    except Exception as e:
        log(f"WARNING: optional {part}.img was not extracted: {e}")
        return None
    path = os.path.join(out_dir, part + ".img")
    return path if os.path.exists(path) else None


def unpack_erofs(img, out_dir):
    log("unpacking " + os.path.basename(img))
    run([EXTRACT, "-i", img, "-x", "-s", "-f", "-o", out_dir], quiet=True)


def tree_text(root, names=("build.prop",)):
    chunks = []
    for base, _dirs, files in os.walk(root):
        for fn in files:
            if fn in names:
                path = os.path.join(base, fn)
                try:
                    chunks.append(read_text(path))
                except OSError:
                    pass
    return "\n".join(chunks)


def validate_target(work, skip=False):
    text = tree_text(os.path.join(work, "vendor")) + "\n" + tree_text(os.path.join(work, "odm"))
    matched = [hint for hint in TARGET_HINTS if hint.lower() in text.lower()]
    if matched:
        log("target check: detected %s marker(s): %s" % (TARGET_NAME, ", ".join(matched)))
        return
    msg = (
        "stock vendor/odm do not contain a known OnePlus 9 Pro marker "
        f"({', '.join(TARGET_HINTS)}). Use a genuine OnePlus 9 Pro stock OTA."
    )
    if skip:
        log("WARNING: " + msg + " -- continuing because --skip-target-check was used")
    else:
        die(msg)


def merge_tree(src, dst):
    if not os.path.isdir(src):
        return
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(src):
        s = os.path.join(src, name)
        d = os.path.join(dst, name)
        if os.path.isdir(s):
            merge_tree(s, d)
        else:
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.move(s, d)
    shutil.rmtree(src, ignore_errors=True)


def copy_tree(src, dst):
    for base, _dirs, files in os.walk(src):
        rel = os.path.relpath(base, src)
        target = dst if rel == "." else os.path.join(dst, rel)
        os.makedirs(target, exist_ok=True)
        for fn in files:
            shutil.copy2(os.path.join(base, fn), os.path.join(target, fn))


def prop_append(path, block, header=None):
    lines = read_lines(path) if os.path.exists(path) else []
    present = set(x.strip() for x in lines)
    add = [x for x in block if x.strip() and x.strip() not in present]
    if not add:
        return
    if header:
        lines += ["", header]
    lines += add
    write_lines(path, lines)


def prop_remove_prefix(path, prefix):
    if not os.path.exists(path):
        return
    lines = read_lines(path)
    write_lines(path, [x for x in lines if not x.strip().startswith(prefix)])


def read_fix(name):
    path = os.path.join(FIXES_DIR, name)
    if not os.path.exists(path):
        return []
    return [x for x in read_lines(path) if x.strip() and not x.lstrip().startswith("#")]


def prop_set(path, key, value):
    """Set a property, replacing any existing definition.

    prop_append() only adds lines that are not already present, which cannot
    override a value the donor already defines. Boot-critical props need a real
    assignment, so this rewrites the first occurrence and drops any duplicates.
    """
    lines = read_lines(path) if os.path.exists(path) else []
    prefix = key + "="
    out, written = [], False
    for line in lines:
        if line.strip().startswith(prefix):
            if not written:
                out.append(prefix + value)
                written = True
            continue
        out.append(line)
    if not written:
        out.append(prefix + value)
    write_lines(path, out)


def apply_zygote_abi_fix(system_bp):
    """Stop system_server from waiting on a 32-bit zygote that never starts.

    The OnePlus 9 Pro vendor advertises 32-bit ABIs
    (ro.vendor.product.cpu.abilist32=armeabi-v7a,armeabi) but ro.zygote=zygote64
    starts only the 64-bit zygote, so /dev/socket/zygote_secondary is never
    created. HyperOS donors ship ro.system.product.cpu.abilist32 empty, which
    lets the vendor value become the device-wide ro.product.cpu.abilist32. The
    framework then believes 32-bit apps are supported, asks ZygoteProcess for
    the secondary zygote, and spins forever on

        W ZygoteProcess: Got error connecting to zygote, retrying.
                         msg= No such file or directory

    so boot never completes and init restarts the framework in a loop.

    /system/build.prop is loaded before /vendor/build.prop and ro.* properties
    are first-writer-wins, so pinning the values here beats the vendor. These
    match the ColorOS 16 configuration that boots on this device.
    """
    for key, value in (
        ("ro.product.cpu.abilist", "arm64-v8a"),
        ("ro.product.cpu.abilist32", ""),
        ("ro.product.cpu.abilist64", "arm64-v8a"),
    ):
        prop_set(system_bp, key, value)


def apply_debuggable(system_bp):
    """Leave adbd reachable without authorisation.

    Userdata is wiped on flash, so there is no adb key and USB debugging is off:
    without this a boot failure is undiagnosable. Note it also makes adb
    unauthenticated, so only ship it on a debug build.
    """
    for key, value in (
        ("ro.debuggable", "1"),
        ("ro.force.debuggable", "1"),
        ("ro.secure", "0"),
        ("ro.adb.secure", "0"),
    ):
        prop_set(system_bp, key, value)


def detect_stock_density(work):
    for root in (os.path.join(work, "vendor"), os.path.join(work, "odm")):
        for base, _dirs, files in os.walk(root):
            if "build.prop" not in files:
                continue
            for line in read_lines(os.path.join(base, "build.prop")):
                if line.startswith("ro.sf.lcd_density="):
                    value = line.split("=", 1)[1].strip()
                    if value.isdigit():
                        return value
    return None


def set_density(product_bp, density):
    if not density:
        return
    prop_remove_prefix(product_bp, "persist.miui.density_v2=")
    prop_remove_prefix(product_bp, "ro.sf.lcd_density=")
    prop_append(product_bp, [f"persist.miui.density_v2={density}", f"ro.sf.lcd_density={density}"],
                header="# OnePlus 9 Pro density")


def _xml_set_int(text, name, value):
    """Replace <integer name="NAME">..</integer> in a MIUI device_features file."""
    pat = r'(<integer\s+name="%s"\s*>)(-?\d+)(</integer>)' % re.escape(name)
    m = re.search(pat, text)
    if not m:
        return text, None
    if m.group(2) == str(value):
        return text, m.group(2)
    return re.sub(pat, r"\g<1>%s\g<3>" % value, text, count=1), m.group(2)


def apply_display_fixes(work):
    """Undo two pieces of donor-specific display config.

    The donor is ishtar (Xiaomi 13 Ultra): centre punch-hole, and a MIUI
    device_features file that defaults the panel to 60 Hz.

    1. product/overlay/DevicesAndroidOverlay.apk is the donor's framework-res
       RRO. Static RRO priority is by partition (product beats odm), so its
       config_mainBuiltInDisplayCutout -- a centred spec, "M 0,0 H -42 V 144
       H 42 V 0 H 0 Z" -- buries the correct left-anchored lemonadep spec that
       ColorOS ships in /odm/overlay. It is immutable, so it cannot be turned
       off at runtime; it has to go from the image. Removing it also drops 22
       other donor values (doze component, status bar heights, corner radii).

    2. device_features/<donor>.xml carries defaultFps=60, which is what makes
       Settings.System.peak_refresh_rate resolve to 60 on a fresh userdata even
       though the panel advertises 120. display_width is the donor's 3200;
       lemonadep is 3216.
    """
    product = os.path.join(work, "product")

    rro = os.path.join(product, "overlay", "DevicesAndroidOverlay.apk")
    if os.path.exists(rro):
        os.remove(rro)
        log("      removed donor framework RRO: product/overlay/DevicesAndroidOverlay.apk")
    else:
        log("      donor framework RRO not present; nothing to remove")

    feat_dir = os.path.join(product, "etc", "device_features")
    if not os.path.isdir(feat_dir):
        log("      no product/etc/device_features; skipping fps default")
        return
    for name in sorted(os.listdir(feat_dir)):
        if not name.endswith(".xml"):
            continue
        path = os.path.join(feat_dir, name)
        text = io.open(path, encoding="utf-8").read()
        orig = text
        text, was = _xml_set_int(text, "defaultFps", 120)
        if was is not None and was != "120":
            log("      %s: defaultFps %s -> 120" % (name, was))
        text, was = _xml_set_int(text, "display_width", 3216)
        if was is not None and was != "3216":
            log("      %s: display_width %s -> 3216" % (name, was))
        if text != orig:
            with io.open(path, "w", encoding="utf-8") as fh:
                fh.write(text)


BIOMETRIC_FEATURES_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- Added by the OP9P port.

     Neither side of the port declares these. OPlus declares
     android.hardware.fingerprint from their /system, Xiaomi declares it from
     their /vendor; the port takes system from Xiaomi and vendor from OPlus, so
     each declaration lives in the partition the other side supplied and both
     are lost. Without them PackageManager.hasSystemFeature() is false and
     Settings renders no fingerprint or face tile at all, even though
     /vendor/bin/hw has both HALs:
       vendor.oplus.hardware.biometrics.fingerprint@2.1-service
       android.hardware.biometrics.face@1.0-service.faceauth
-->
<permissions>
    <feature name="android.hardware.fingerprint" />
    <feature name="android.hardware.biometrics.face" />
</permissions>
"""


OVERLAYS_DIR = os.path.join(HERE, "overlays")


def install_overlays(work):
    """Install our own RRO overlays into system_ext/overlay.

    Static RRO priority is by partition (system < vendor < odm < product <
    system_ext), so an overlay here outranks every HyperOS overlay -- including
    DevicesAndroidOverlay in /product, which is what buries the correct cutout.
    These are built by tools/apk (aapt2 + apksigner) and signed with
    tools/apk/op9p.keystore; /product and /system_ext are system partitions, so
    a self-signed RRO is accepted there.
    """
    if not os.path.isdir(OVERLAYS_DIR):
        return
    apks = []
    for root, _dirs, files in os.walk(OVERLAYS_DIR):
        for f in files:
            if f.endswith(".apk"):
                apks.append(os.path.join(root, f))
    if not apks:
        return
    dst = os.path.join(work, "system_ext", "overlay")
    if not os.path.isdir(dst):
        os.makedirs(dst)
    for apk in sorted(apks):
        shutil.copy2(apk, os.path.join(dst, os.path.basename(apk)))
        log("      installed system_ext/overlay/" + os.path.basename(apk))


def apply_biometric_features(work):
    """Declare fingerprint + face so Settings shows the enrolment options."""
    d = os.path.join(work, "product", "etc", "permissions")
    if not os.path.isdir(d):
        os.makedirs(d)
    path = os.path.join(d, "op9p-port-biometrics.xml")
    with io.open(path, "w", encoding="utf-8") as fh:
        fh.write(BIOMETRIC_FEATURES_XML)
    log("      declared android.hardware.fingerprint + biometrics.face")


def apply_market_name(system_bp, prod_bp, name="OnePlus 9 Pro"):
    """Show 'OnePlus 9 Pro' instead of the LE2123 model code.

    ro.product.model is deliberately left alone: it is part of the build
    fingerprint that apps and attestation match against. HyperOS renders
    ro.product.marketname when it is set, which is the cosmetic string.
    """
    for bp in (system_bp, prod_bp):
        if os.path.exists(bp):
            prop_set(bp, "ro.product.marketname", name)
            prop_set(bp, "ro.vendor.oplus.market.name", name)
    log("      ro.product.marketname = " + name)


APPS_DIR = os.path.join(HERE, "apps")


def bundle_extra_apps(work):
    """Install any APK in apps/ as a product system app.

    MIUI Camera is built against Xiaomi's camera stack (MiAlgo/mihal vendor
    tags). This port keeps ColorOS's vendor, which ships the stock Qualcomm HAL
    (camera.qcom.so) and none of those extensions, so MIUI Camera refuses to
    start with "model not supported". The HAL itself is fine -- it enumerates
    six cameras -- so a plain Camera2 app works. Open Camera is bundled as a
    camera that actually functions; MIUI Camera is deliberately left installed.
    """
    if not os.path.isdir(APPS_DIR):
        return
    apks = sorted(x for x in os.listdir(APPS_DIR) if x.endswith(".apk"))
    if not apks:
        return
    for apk in apks:
        name = os.path.splitext(apk)[0]
        dst = os.path.join(work, "product", "app", name)
        if not os.path.isdir(dst):
            os.makedirs(dst)
        shutil.copy2(os.path.join(APPS_DIR, apk), os.path.join(dst, apk))
        log("      bundled product/app/%s/%s" % (name, apk))


def assemble(work, mi_ext_dir, density=None, debuggable=True):
    product = os.path.join(work, "product")
    system_sys = os.path.join(work, "system", "system")
    system_ext = os.path.join(work, "system_ext")
    prod_bp = os.path.join(product, "etc", "build.prop")
    system_bp = os.path.join(system_sys, "build.prop")

    if mi_ext_dir and os.path.isdir(mi_ext_dir):
        log("[1] folding mi_ext into product + system")
        merge_tree(os.path.join(mi_ext_dir, "product"), product)
        merge_tree(os.path.join(mi_ext_dir, "system"), system_sys)
        mi_bp = os.path.join(mi_ext_dir, "etc", "build.prop")
        if os.path.exists(mi_bp):
            extra = [x for x in read_lines(mi_bp) if not x.strip().startswith("ro.vendor.build.ab_ota_partitions=")]
            for target in (prod_bp, os.path.join(system_sys, "build.prop")):
                base = read_lines(target) if os.path.exists(target) else []
                write_lines(target, base + [""] + extra)
    else:
        log("[1] donor has no mi_ext; skipping mi_ext merge")

    log("[2] applying generic HyperOS system props")
    prop_append(system_bp, read_fix("system.build.prop"), header="# port fixes")

    log("[3] pinning CPU ABI list (required: 64-bit-only zygote on a 64/32 vendor)")
    apply_zygote_abi_fix(system_bp)

    if debuggable:
        log("[3b] making the build debuggable (adb stays reachable on a boot failure)")
        apply_debuggable(system_bp)

    log("[4] relocating product/pangu/system when present")
    merge_tree(os.path.join(product, "pangu", "system"), system_sys)

    log("[5] removing qcrilmsgtunnel to avoid Qualcomm RIL duplication")
    shutil.rmtree(os.path.join(system_ext, "priv-app", "qcrilmsgtunnel"), ignore_errors=True)

    if density:
        log("[6] applying target density: " + str(density))
        set_density(prod_bp, str(density))
    else:
        log("[6] no target density available; preserving donor density")

    log("[7] fixing donor display config (cutout position + 120 Hz default)")
    apply_display_fixes(work)

    log("[8] declaring biometric features (fingerprint + face)")
    apply_biometric_features(work)

    log("[9] setting the marketing name")
    apply_market_name(system_bp, prod_bp)

    log("[10] bundling extra apps")
    bundle_extra_apps(work)

    log("[11] installing port RRO overlays")
    install_overlays(work)


def apply_res(work, res_dir):
    if not os.path.isdir(res_dir):
        return
    log("[RES] applying user/device overlays")
    for part in PACK:
        src = os.path.join(res_dir, part)
        if os.path.isdir(src):
            copy_tree(src, os.path.join(work, part))


def pack_partition(work, part, out_dir, ts):
    img = os.path.join(out_dir, part + ".img")
    fsc = os.path.join(work, "config", part + "_fs_config")
    fc = os.path.join(work, "config", part + "_file_contexts")
    run([MKFS, "-zlz4hc,0", "-T", str(ts), "--mount-point=/" + part,
         "--product-out=" + work, "--fs-config-file=" + fsc,
         "--file-contexts=" + fc, img, os.path.join(work, part)], quiet=True)
    return img


def make_zip(imgs, path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        for img in imgs:
            z.write(img, os.path.basename(img))


def main(argv=None):
    ap = argparse.ArgumentParser(description="HyperOS -> OnePlus 9 Pro auto-porter")
    ap.add_argument("--stock", required=True, help="OnePlus 9 Pro stock ROM (URL/zip/payload.bin/dir)")
    ap.add_argument("--hyperos", "--hos", "--hos4", dest="hyperos", required=True,
                    help="HyperOS donor ROM (URL/zip/payload.bin/dir)")
    ap.add_argument("--work", default="work")
    ap.add_argument("--out", default="out")
    ap.add_argument("--res", default=os.path.join(HERE, "RES"))
    ap.add_argument("--name", default="HyperOS-OnePlus9Pro-port")
    ap.add_argument("--density", type=int, help="override logical LCD density; otherwise auto-detect when possible")
    ap.add_argument("--skip-target-check", action="store_true")
    ap.add_argument("--keep-work", action="store_true")
    ap.add_argument("--no-zip", dest="zip", action="store_false",
                    help="skip the images zip; make_rom.sh packs super from the raw images")
    ap.add_argument("--no-debuggable", dest="debuggable", action="store_false",
                    help="ship ro.debuggable=0 and authenticated adb; without this a boot "
                         "failure cannot be diagnosed, since flashing wipes the adb key")
    args = ap.parse_args(argv)

    for tool in (MKFS, EXTRACT):
        if not os.path.exists(tool):
            die("missing tool: " + tool)
        os.chmod(tool, 0o755)

    work = os.path.abspath(args.work)
    out = os.path.abspath(args.out)
    dl = os.path.join(work, "_inputs")
    if os.path.exists(work) and not args.keep_work:
        shutil.rmtree(work)
    os.makedirs(dl, exist_ok=True)
    os.makedirs(out, exist_ok=True)

    log("== resolving inputs ==")
    stock_src = resolve_input(args.stock, dl, "stock")
    donor_src = resolve_input(args.hyperos, dl, "hyperos")

    log("== extracting payloads ==")
    stock = get_required_images(stock_src, os.path.join(dl, "stock_img"), FROM_STOCK, "stock")
    donor = get_required_images(donor_src, os.path.join(dl, "hyperos_img"), FROM_HYPEROS_REQUIRED, "hyperos")
    mi_ext_img = get_optional_image(donor_src, os.path.join(dl, "hyperos_mi_ext"), "mi_ext")

    log("== unpacking target stock vendor/odm ==")
    for part in FROM_STOCK:
        unpack_erofs(stock[part], work)
    validate_target(work, args.skip_target_check)
    stock_density = detect_stock_density(work)

    log("== unpacking HyperOS donor ==")
    for part in FROM_HYPEROS_REQUIRED:
        unpack_erofs(donor[part], work)
    mi_ext_dir = None
    if mi_ext_img:
        unpack_erofs(mi_ext_img, work)
        mi_ext_dir = os.path.join(work, "mi_ext")

    density = args.density or stock_density
    assemble(work, mi_ext_dir, density=density, debuggable=args.debuggable)
    apply_res(work, args.res)

    log("== syncing SELinux config ==")
    for part in PACK:
        sync_config(work, part)

    log("== packing images ==")
    ts = int(time.time())
    imgs = [pack_partition(work, p, out, ts) for p in PACK]
    if args.zip:
        zip_path = os.path.join(out, args.name + ".zip")
        make_zip(imgs, zip_path)
        log("done: " + zip_path)
    else:
        log("done: " + out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
