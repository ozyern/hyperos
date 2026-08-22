#!/usr/bin/env bash
# Build a fastboot-flashable HyperOS super.img for the OnePlus 9 Pro (lemonadep).
#
# HyperOS donor supplies system/system_ext/product; the ColorOS 16 build supplies
# the hardware side (vendor, odm, my_*) and the boot chain. Both must come from
# the SAME generation as the critical firmware already on the device: abl/tz/hyp/
# keymaster refuse fastboot writes, so a mismatched boot chain gives splash ->
# fastboot and looks exactly like an AVB rejection.
#
# Usage:
#   ./make_rom.sh <brinaos-ota.zip|IMAGES-dir> <hyperos-donor.zip|dir>
#   ./make_rom.sh                                  # use the defaults below
#   SKIP_PORT=1 ./make_rom.sh                      # repack super only
#   EXTRACT_ONLY=1 ./make_rom.sh ...               # just fill the input cache
#
# Each build lands in its own out_hos/run-N/, with out_hos/latest pointing at
# the newest, so a run can never overwrite the last known-good super.img.
# SKIP_PORT=1 repacks the newest run in place instead of starting a new one.
#
# Both args take an OTA zip, a payload.bin, or a dir of extracted images.
# Arg 1 is the ColorOS 16 side and must be BrinaOS's OWN output -- its ota_full
# zip or its IMAGES dir -- not a stock OnePlus OTA: the port needs the vendor,
# odm and my_* that BrinaOS built. A zip is extracted once into cos_img/<name>/
# and reused, so only the first run pays for it.
#
# NO_COLOR=1 strips the styling, and output goes plain whenever stdout is not a
# tty, so piped logs stay greppable.
#
# Flash (Windows, WSL has no USB):
#   flash-op9p.ps1 -Super <out_hos/super.img> -FwDir <COS_IMAGES> -Slot b
set -euo pipefail

B="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TMPDIR="${TMPDIR:-$B/tmp}"; mkdir -p "$TMPDIR"

# ------------------------------------------------------------------ aesthetics
# Short n' Sweet: pink when a terminal is watching, plain when it is not.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  HOT=$'\033[38;5;211m'; SOFT=$'\033[38;5;218m'; CREAM=$'\033[38;5;230m'
  LAV=$'\033[38;5;183m'; GOLD=$'\033[38;5;222m'; RED=$'\033[38;5;204m'
  DIM=$'\033[2m'; BLD=$'\033[1m'; OFF=$'\033[0m'
else
  HOT= SOFT= CREAM= LAV= GOLD= RED= DIM= BLD= OFF=
fi

banner() {
  printf "\n"
  printf "  %s.:*+--+*:.%s  %sS H O R T   N '   S W E E T%s  %s.:*+--+*:.%s\n" \
         "$SOFT" "$OFF" "$BLD$HOT" "$OFF" "$SOFT" "$OFF"
  printf "  %shyperos%s %s<3%s %soneplus 9 pro%s   %slemonadep / sm8350%s\n\n" \
         "$LAV" "$OFF" "$HOT" "$OFF" "$LAV" "$OFF" "$DIM" "$OFF"
}

STEP=0
# say <song> <what it is actually doing>
say() {
  STEP=$((STEP + 1))
  printf "\n %s%02d%s %s*%s %s%s%s  %s~ %s%s\n" \
    "$DIM$LAV" "$STEP" "$OFF" "$HOT" "$OFF" "$BLD$CREAM" "$2" "$OFF" \
    "$DIM" "$1" "$OFF"
}
note() { printf "    %s%-14s%s %s%s%s\n" "$DIM$LAV" "$1" "$OFF" "$CREAM" "$2" "$OFF"; }
tick() { printf "    %s+%s %s\n" "$GOLD" "$OFF" "$1"; }
die() {
  printf "\n %s!! manchild%s %s%s%s\n" "$BLD$RED" "$OFF" "$CREAM" "$1" "$OFF" >&2
  shift
  for l in "$@"; do printf "    %s%s%s\n" "$DIM" "$l" "$OFF" >&2; done
  exit 1
}

case "${1:-}" in
  -h|--help)
    banner
    sed -n '2,${/^#/!q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0 ;;
esac

banner

# Positional args win over the environment, which wins over these defaults.
COS=${1:-${COS:-/home/brina/BrinaOS/out/target/product/OnePlus9Pro/IMAGES}}
DONOR=${2:-${DONOR:-/home/brina/13.zip}}
WORK=${WORK:-$B/work_cos}
RUNS=${RUNS:-$B/out_hos}
OUT=${OUT:-}
SLOT=${SLOT:-b}
EROFS=$B/bin/Linux/x86_64
FLASHER_TPL=${FLASHER_TPL:-/mnt/c/Users/gameb/Downloads/fastbootflasher-v3-20260203.zip}

# The six images that live outside super and must be flashed alongside it.
FW_PARTS="boot dtbo vendor_boot vbmeta vbmeta_system vbmeta_vendor"

# my_* are first_stage_mount WITHOUT nofail, so every one must exist and mount.
# my_stock is 2.8 GB of ColorOS APKs that a HyperOS system never uses, and the
# port does not fit in super with it; rebuild it as a skeleton keeping
# build.prop + etc/ + applist so its ro.oplus.version.* props survive.
STUB_PARTS=${STUB_PARTS:-my_stock}
PASSTHRU="my_product my_engineering my_stock my_carrier my_region my_bigball my_heytap my_manifest my_company my_preload"

[ -e "$COS" ] || die "ColorOS 16 side not found: $COS" \
  "arg 1 takes BrinaOS's ota_full zip, a payload.bin, or its IMAGES dir."
[ -e "$DONOR" ] || die "HyperOS donor not found: $DONOR" \
  "arg 2 takes a donor OTA zip, a payload.bin, or a dir of extracted images."

# Everything the build packs plus the six images the flasher writes, so one
# extraction serves both and the flash FwDir is just the resolved COS dir.
COS_PARTS="vendor odm $PASSTHRU boot dtbo vendor_boot vbmeta vbmeta_system vbmeta_vendor"

have_all() { for c in $COS_PARTS; do [ -e "$1/$c.img" ] || return 1; done; return 0; }

if [ ! -d "$COS" ]; then
  SRC=$COS
  COS=$B/cos_img/$(basename "${SRC%.*}")
  if [ -e "$COS/.complete" ] && have_all "$COS"; then
    say "Taste" "reusing the ColorOS side we already unpacked"
  else
    say "Espresso" "extracting ColorOS side from $(basename "$SRC")"
    rm -rf "$COS"; mkdir -p "$COS"
    PAYLOAD=$SRC
    if [ "${SRC##*.}" = zip ]; then
      # Unzip to disk first: payload-dumper-go otherwise spools the whole
      # payload into TMPDIR, and WSL's /tmp is a 3.8 GB tmpfs.
      unzip -o -q -d "$COS" "$SRC" payload.bin
      PAYLOAD=$COS/payload.bin
    fi
    "$B/bin/Linux/x86_64/payload-dumper-go" \
      -p "$(echo $COS_PARTS | tr ' ' ,)" -o "$COS" "$PAYLOAD" >/dev/null
    if [ "$PAYLOAD" = "$COS/payload.bin" ]; then rm -f "$PAYLOAD"; fi
    have_all "$COS" || die "extraction is missing images in $COS"
    touch "$COS/.complete"
  fi
fi

for i in vendor odm; do
  [ -e "$COS/$i.img" ] || die "$COS has no $i.img -- is this really BrinaOS's output?"
done

note "coloros side" "$COS"
note "hyperos donor" "$DONOR"
[ -z "${EXTRACT_ONLY:-}" ] || {
  printf "\n    %sEXTRACT_ONLY set - stopping after input resolution.%s\n" "$DIM" "$OFF"
  exit 0; }

# BrinaOS wipes its work dirs at the top of every run, AFTER validating inputs,
# so a bad invocation cannot destroy the previous build. Same order here.
# cos_img/ is the extracted-input cache rather than work, so it survives.
say "House Tour" "clearing out the work dirs"
rm -rf "$B/cos_stock" "$B/cos_passthru" "$B/stub_work" "$B/stubs"
if [ -z "${SKIP_PORT:-}" ]; then rm -rf "$WORK"; fi
mkdir -p "$TMPDIR"

# One folder per run: a build can never overwrite the last known-good super.
if [ -n "${SKIP_PORT:-}" ]; then
  if [ -z "$OUT" ]; then
    OUT=$(ls -d "$RUNS"/run-* 2>/dev/null | sort -V | tail -1 || true)
  fi
  [ -n "$OUT" ] && [ -d "$OUT" ] || die \
    "SKIP_PORT=1 repacks a previous run, but none exists under $RUNS" \
    "drop SKIP_PORT to build one."
else
  if [ -z "$OUT" ]; then
    n=1; while [ -e "$RUNS/run-$n" ]; do n=$((n + 1)); done
    OUT=$RUNS/run-$n
  fi
fi
mkdir -p "$OUT"
ln -sfn "$OUT" "$RUNS/latest"
note "output" "$OUT"

say "Good Graces" "staging the ColorOS 16 hardware side"
mkdir -p "$B/cos_stock" "$B/cos_passthru" "$OUT"
ln -sf "$COS/vendor.img" "$B/cos_stock/vendor.img"
ln -sf "$COS/odm.img"    "$B/cos_stock/odm.img"
for p in $PASSTHRU; do ln -sf "$COS/$p.img" "$B/cos_passthru/$p.img"; done

if [ -z "${SKIP_PORT:-}" ]; then
  say "Bed Chem" "porting the HyperOS system side onto the ColorOS vendor"
  # No --keep-work: $WORK is dedicated to port.py, so let it wipe and rebuild for
  # a clean tree. Keeping it would re-fold mi_ext and re-move product/pangu onto
  # an already-assembled tree on a rerun.
  python3 "$B/port.py" \
    --stock "$B/cos_stock" --hyperos "$DONOR" \
    --work "$WORK" --out "$OUT" --name "HyperOS-OP9P" --no-zip
fi

# Use the pristine ColorOS vendor/odm rather than port.py's repack: they are
# byte-identical in size, and not rebuilding them cannot lose SELinux labels.
ln -sf "$COS/vendor.img" "$OUT/vendor.img"
ln -sf "$COS/odm.img"    "$OUT/odm.img"

for p in $STUB_PARTS; do
  say "Skinny Dipping" "stripping $p down to a skeleton"
  W=$B/stub_work/$p
  rm -rf "$W"; mkdir -p "$W" "$B/stubs"
  "$EROFS/extract.erofs" -i "$COS/$p.img" -x -s -f -o "$W" >/dev/null 2>&1
  for d in app del-app media non_overlay lib lib64 priv-app; do rm -rf "$W/$p/$d"; done
  mkdir -p "$W/$p/app"
  "$EROFS/mkfs.erofs" -zlz4hc,0 --mount-point="/$p" --product-out="$W" \
    --fs-config-file="$W/config/${p}_fs_config" \
    --file-contexts="$W/config/${p}_file_contexts" \
    "$B/stubs/$p.img" "$W/$p" >/dev/null
  ln -sf "$B/stubs/$p.img" "$B/cos_passthru/$p.img"
  tick "$(printf '%s: %s -> %s bytes' "$p" \
          "$(stat -Lc%s "$COS/$p.img")" "$(stat -Lc%s "$B/stubs/$p.img")")"
done

say "Please Please Please" "packing super.img"
SLOT=$SLOT OUT=$OUT STOCK=$B/cos_passthru SUPER_OUT=$OUT/super.img \
PASSTHRU="$PASSTHRU" "$B/build_super.sh" 2>&1 | grep -vE "Invalid sparse|liblp\]Partition"

say "Sharpest Tool" "verifying the super metadata"
python3 "$B/verify_super.py" "$OUT/super.img" | tail -4

# The boot chain lives in physical partitions outside super, so a run dir that
# only holds super.img is not a flashable ROM. Copy (not symlink) the six
# images in, so out_hos/run-N is self-contained and survives cos_img changing.
say "Nonsense" "staging the boot chain into the run dir"
for f in $FW_PARTS; do
  cp -f --remove-destination "$COS/$f.img" "$OUT/$f.img"
done
tick "$(echo $FW_PARTS | wc -w) firmware images staged"

# Wrap it all in the fastboot-flasher template so the ROM installs itself.
if [ -f "$FLASHER_TPL" ]; then
  say "Espresso" "packaging the self-installing flasher zip"
  PKG=$TMPDIR/pkg
  rm -rf "$PKG"; mkdir -p "$PKG/images"
  unzip -o -q "$FLASHER_TPL" -d "$PKG"

  # installer.sh looks for tools/<os>/fastboot; the template ships it one level
  # deeper under platform-tools/. Put a copy where the script expects it.
  # installer.bat puts tools\windows on PATH and calls bare `fastboot`, but the
  # template ships the binaries a level deeper. Flatten both, and copy the whole
  # toolset rather than just fastboot: fastboot.exe needs AdbWinApi.dll beside it.
  cp -f "$PKG/tools/linux/platform-tools/"*   "$PKG/tools/linux/"   2>/dev/null || true
  cp -f "$PKG/tools/windows/platform-tools/"* "$PKG/tools/windows/" 2>/dev/null || true
  chmod -R +x "$PKG/tools/linux" 2>/dev/null || true

  cp -f "$OUT/super.img" "$PKG/images/"
  for f in $FW_PARTS; do cp -f "$OUT/$f.img" "$PKG/images/"; done

  # The template hardcodes slot a. Retarget it to whatever slot we packed, or
  # the device activates a slot whose logical partitions are empty.
  sed -i "s/_a\"/_$SLOT\"/g; s/set_active a/set_active $SLOT/g" "$PKG/installer.sh"
  sed -i "s/!imgName!_a /!imgName!_$SLOT /g; s/set_active a/set_active $SLOT/g" "$PKG/installer.bat"

  # COMPATIBLE is matched against `fastboot getvar product`, which on this
  # device is the SoC name (lahaina), not the model.
  cat > "$PKG/config.txt" <<CFG
DEVICE=OnePlus 9 Pro (lemonadep) - HyperOS 3
COMPATIBLE=lahaina
PRELOADER=
DISABLE_VERITY=true
IMAGES=$(echo $FW_PARTS | tr ' ' '\n' | sed 's/$/.img/' | tr '\n' ',')super.img
CFG

  # HyperOS defaults the panel to 60 Hz through config_defaultRefreshRate in
  # FrameworksResCommon_Sys.apk (57 mapped resources, signed) so it cannot be
  # changed cleanly in the image. Settings.System overrides it but lives in
  # userdata, which this installer wipes -- so re-apply it after first boot.
  # adb is bundled and ro.adb.secure=0, so no interaction is needed.
  cat >> "$PKG/installer.sh" <<'POST'

echo "Waiting for first boot to apply 120 Hz..."
"$SCRIPT_PATH/tools/linux/adb" wait-for-device >/dev/null 2>&1
for i in $(seq 1 40); do
    sleep 10
    if [ "$("$SCRIPT_PATH/tools/linux/adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '')" = "1" ]; then
        "$SCRIPT_PATH/tools/linux/adb" shell settings put system peak_refresh_rate 120 >/dev/null 2>&1
        "$SCRIPT_PATH/tools/linux/adb" shell settings put system min_refresh_rate 60 >/dev/null 2>&1
        echo "120 Hz applied."
        break
    fi
done
POST

  cat >> "$PKG/installer.bat" <<'POST'

echo Waiting for first boot to apply 120 Hz...
adb wait-for-device >nul 2>&1
for /l %%i in (1,1,40) do (
    timeout /t 10 /nobreak >nul
    for /f "usebackq delims=" %%B in (`adb shell getprop sys.boot_completed 2^>nul`) do set BC=%%B
    if "!BC!"=="1" (
        adb shell settings put system peak_refresh_rate 120 >nul 2>&1
        adb shell settings put system min_refresh_rate 60 >nul 2>&1
        echo 120 Hz applied.
        goto :hyperos_done
    )
)
:hyperos_done
POST

  ZIP=$OUT/HyperOS-OP9P-slot$SLOT-flasher.zip
  rm -f "$ZIP"
  ( cd "$PKG" && zip -r -q "$ZIP" . )
  rm -rf "$PKG"
  tick "$(basename "$ZIP")  ($(du -h "$ZIP" | cut -f1))"
else
  printf "    %sflasher template not found at %s - skipping zip%s\n" "$DIM" "$FLASHER_TPL" "$OFF"
fi

printf "\n  %s.:*+--+*:.%s  %sthat's that me espresso%s  %s.:*+--+*:.%s\n" \
       "$SOFT" "$OFF" "$BLD$HOT" "$OFF" "$SOFT" "$OFF"
note "rom ready" "$OUT/super.img  (slot $SLOT)"
if [ -f "$OUT/HyperOS-OP9P-slot$SLOT-flasher.zip" ]; then
  note "installer" "$OUT/HyperOS-OP9P-slot$SLOT-flasher.zip  (unzip, run installer.bat)"
fi
note "or flash" "flash-op9p.ps1 -Super $OUT/super.img -FwDir $OUT -Slot $SLOT"
printf "\n"
