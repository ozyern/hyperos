#!/usr/bin/env bash
# Vet a candidate donor OTA against OnePlus 9 Pro (lemonadep) requirements.
#   ./vet_donor.sh /home/brina/13u.zip
set -uo pipefail
B="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TMPDIR="${TMPDIR:-$B/tmp}"; mkdir -p "$TMPDIR"
SRC="${1:?usage: vet_donor.sh <donor.zip|payload.bin>}"
V=$B/vet
PDG=$B/bin/Linux/x86_64/payload-dumper-go
EX=$B/bin/Linux/x86_64/extract.erofs
rm -rf "$V"; mkdir -p "$V/img" "$TMPDIR"

echo "############ 1. OTA metadata ############"
if [[ "$SRC" == *.zip ]]; then
  python3 - "$SRC" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
try:
    m = z.read('META-INF/com/android/metadata').decode('utf8', 'replace')
except KeyError:
    m = ''
keys = ('post-build=', 'android_version', 'post-sdk-level', 'pre-device',
        'post-security-patch-level', 'post-build-incremental')
for line in m.splitlines():
    if any(k in line for k in keys):
        print('   ', line)
PY
  echo "==> extracting payload.bin to disk"
  mkdir -p "$V/zip"
  (cd "$V/zip" && unzip -o -q "$SRC" payload.bin) || exit 1
  PAYLOAD="$V/zip/payload.bin"
else
  PAYLOAD="$SRC"
fi

echo
echo "############ 2. extracting system + system_ext ############"
"$PDG" -p system,system_ext -o "$V/img" "$PAYLOAD" >/dev/null 2>&1 || {
  echo "  payload-dumper-go failed"; exit 1; }
ls -la "$V/img"

"$EX" -i "$V/img/system.img"     -x -s -f -o "$V/s"  >/dev/null 2>&1
"$EX" -i "$V/img/system_ext.img" -x -s -f -o "$V/se" >/dev/null 2>&1

n32=$(ls "$V/s/system/system/lib"   2>/dev/null | wc -l)
n64=$(ls "$V/s/system/system/lib64" 2>/dev/null | wc -l)

echo
echo "############ 3. VERDICT ############"
echo
printf 'CHECK 1  32-bit runtime   : system/lib=%s  system/lib64=%s\n' "$n32" "$n64"
if [ "$n32" -gt 100 ]; then echo "         => PASS (64_32 build, SD888 vendor 32-bit HALs can link)"
else echo "         => FAIL (64-bit-only donor; unusable on lemonadep)"; fi
echo
echo "CHECK 2  VNDK apexes in system_ext:"
ls "$V/se/system_ext/apex" 2>/dev/null | grep -i vndk | sed 's/^/           /' || echo "           (none)"
if [ -e "$V/se/system_ext/apex/com.android.vndk.v30.apex" ]; then
  echo "         => PASS (ships v30 natively)"
else
  echo "         => OK via transplant (RES/system_ext/apex/com.android.vndk.v30.apex is staged)"
fi
echo
hw=""
[ -e "$V/se/system_ext/bin/hwservicemanager" ] && hw="system_ext/bin"
[ -e "$V/s/system/system/bin/hwservicemanager" ] && hw="${hw:+$hw and }system/bin"
printf 'CHECK 3  hwservicemanager : %s\n' "${hw:-ABSENT}"
if [ -n "$hw" ]; then echo "         => PASS (49 OPlus HIDL HALs can register)"
else echo "         => FAIL (no HIDL registry; vendor HALs cannot start)"; fi
echo
echo "CHECK 4  zygote / abilist props:"
grep -rhE '^(ro\.zygote|ro\.product\.cpu\.abilist.*)=' "$V/s/system/system/build.prop" 2>/dev/null | sed 's/^/           /'
echo
echo "== VET_DONE =="
