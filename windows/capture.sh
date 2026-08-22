#!/usr/bin/env bash
# Grab everything useful from a debuggable device stuck in a framework bootloop.
cd /c/Users/gameb/AppData/Local/Android/Sdk/platform-tools
D=/c/Users/gameb/op9p-port/diag
ADB=./adb.exe

echo "== waiting for adb (up to 5 min) =="
for i in $(seq 1 60); do
  S=$($ADB devices 2>/dev/null | sed -n '2p')
  case "$S" in
    *device*)      echo "adb up: $S"; break ;;
    *unauthorized*) echo "UNAUTHORIZED: $S (ro.adb.secure did not take effect)"; exit 1 ;;
  esac
  sleep 5
done
[ -n "$S" ] || { echo "no adb after 300s"; exit 1; }

$ADB root >/dev/null 2>&1; sleep 3

echo "== crash buffer =="
$ADB logcat -b crash -d > "$D/crash.txt" 2>&1; wc -l < "$D/crash.txt"
echo "== main+system =="
$ADB logcat -b main -b system -d > "$D/logcat.txt" 2>&1; wc -l < "$D/logcat.txt"
echo "== kernel (avc denials) =="
$ADB shell 'dmesg 2>/dev/null | grep -i "avc: *denied" | head -80' > "$D/avc.txt" 2>&1; wc -l < "$D/avc.txt"
echo "== tombstones =="
$ADB shell 'ls -t /data/tombstones/ 2>/dev/null | head -3' > "$D/tomb_list.txt" 2>&1
$ADB shell 'cat /data/tombstones/$(ls -t /data/tombstones/ 2>/dev/null | head -1) 2>/dev/null' > "$D/tombstone.txt" 2>&1
echo "== props =="
$ADB shell 'getprop | grep -Ei "zygote|abilist|vndk|selinux|debuggable|boot.completed|sys.boot"' > "$D/props.txt" 2>&1
echo "CAPTURE_DONE"
