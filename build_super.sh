#!/usr/bin/env bash
# Pack the ported images + stock my_* passthrough into an OP9P super.img.
# Geometry per BrinaOS bin/getSuperSize.sh + brina.sh V-AB branch (proven on lemonadep).
set -euo pipefail
B="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=${OUT:-$B/out}
# Directory holding the my_* passthrough images (default: the OOS14 stock set).
STOCK=${STOCK:-$B/work/_inputs/stock_img}
# Where the packed image lands (default: alongside the ported images).
SUPER_OUT=${SUPER_OUT:-$OUT/super.img}
LPMAKE=$B/tools/lpmake
SUPER_SIZE=11190403072
GROUP=qti_dynamic_partitions
# Which slot gets the real images. The other slot's partitions are created at
# size 0. NOTE: OnePlus refuses fastboot writes to critical firmware
# (abl/tz/hyp/keymaster/...) with "Flashing is not allowed for Critical
# Partitions", so the populated slot must be one whose firmware chain is already
# known-good. On this device that is slot b.
SLOT="${SLOT:-a}"
if [ "$SLOT" = "a" ]; then OTHER=b; else OTHER=a; fi

# ported by port.py
PORTED="system system_ext product vendor odm"
# passthrough straight from the OnePlus stock OTA (OPlus vendor fstab mounts these)
PASSTHRU="${PASSTHRU:-my_product my_engineering my_stock my_carrier my_region my_bigball my_heytap my_manifest}"

args="-F --virtual-ab --output $SUPER_OUT"
args="$args --metadata-size 65536 --super-name super --metadata-slots 3 --block-size 4096"
args="$args --device super:$SUPER_SIZE"
args="$args --group=${GROUP}_a:$SUPER_SIZE --group=${GROUP}_b:$SUPER_SIZE"

total=0
printf '%-16s %14s  %s\n' PARTITION BYTES SOURCE
printf '%.0s-' {1..60}; echo

add() {  # add <name> <img>
  local p=$1 img=$2 src=$3 sz
  sz=$(stat -Lc%s "$img")
  total=$((total + sz))
  printf '%-16s %14d  %s\n' "$p" "$sz" "$src"
  args="$args --partition ${p}_${SLOT}:none:${sz}:${GROUP}_${SLOT} --image ${p}_${SLOT}=${img}"
  args="$args --partition ${p}_${OTHER}:none:0:${GROUP}_${OTHER}"
}

for p in $PORTED; do
  [ -f "$OUT/$p.img" ] || { echo "ERROR: missing ported image $OUT/$p.img" >&2; exit 1; }
  add "$p" "$OUT/$p.img" "port.py"
done
for p in $PASSTHRU; do
  if [[ " ${SKIP_PASSTHRU:-} " == *" $p "* ]]; then
    printf '%-16s %14s  %s
' "$p" "-" "EXCLUDED (SKIP_PASSTHRU)"
    continue
  fi
  if [ -f "$STOCK/$p.img" ]; then add "$p" "$STOCK/$p.img" "stock OTA"
  else echo "  (skip $p - not in stock OTA)"; fi
done

printf '%.0s-' {1..60}; echo
printf '%-16s %14d\n' TOTAL "$total"
printf '%-16s %14d\n' SUPER_SIZE "$SUPER_SIZE"
free=$((SUPER_SIZE - total))
printf '%-16s %14d  (%.2f GiB)\n' HEADROOM "$free" "$(echo "$free/1073741824" | bc -l)"
if [ "$free" -lt 0 ]; then
  echo; echo "ERROR: partitions exceed super by $((-free)) bytes." >&2
  echo "Drop the largest my_* passthrough entries (my_stock/my_heytap/my_bigball) and retry." >&2
  exit 1
fi

echo; echo "== running lpmake =="
# shellcheck disable=SC2086
"$LPMAKE" $args
ls -la "$SUPER_OUT"
echo "== SUPER_DONE =="
