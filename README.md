# HyperOS → OnePlus 9 Pro (lemonadep) fastboot ROM builder

Builds a fastboot-flashable `super.img` that boots HyperOS 3 on a OnePlus 9 Pro,
by pairing a HyperOS donor's **system side** with a ColorOS 16 **hardware side**.

Confirmed booting 2026-08-21: ishtar (Xiaomi 13 Ultra) donor + ColorOS 16
vendor/odm/boot chain.

## Build

    ./make_rom.sh <brinaos-ota.zip|IMAGES-dir> <hyperos-donor.zip|dir>
    ./make_rom.sh                    # same, using the built-in defaults
    SKIP_PORT=1 ./make_rom.sh        # repack super only, after editing work_cos/
    EXTRACT_ONLY=1 ./make_rom.sh ... # just fill the input cache, build nothing

Two zips in, ROM out, same as `sudo ./brina.sh <base.zip> <donor.zip>`:

    ./make_rom.sh /home/brina/BrinaOS/out/16.0.9.403/ota_full-LE2123_*.zip                   /home/brina/13.zip

Arg 1 must be BrinaOS's OWN output, not a stock OnePlus OTA -- the port needs
the ColorOS 16 vendor/odm/my_* that BrinaOS built. Its `ota_full` zip carries
all of that plus the whole boot chain, so one file is the entire hardware side
and the flasher's `-FwDir`; `make_rom.sh` prints the path to use. BrinaOS's
`out/target/product/OnePlus9Pro/IMAGES` dir works too and skips the extraction.

A zip is unpacked once into `cos_img/<name>/` and reused on later runs (a
`.complete` stamp guards against a half-extracted cache). No sudo anywhere:
mkfs.erofs takes ownership and labels from --fs-config-file.

### Output layout

Every build gets its own folder and `out_hos/latest` points at the newest:

    out_hos/run-1/super.img
    out_hos/run-2/super.img
    out_hos/latest -> run-2

So a fresh run can never overwrite the last super.img you know boots.
`SKIP_PORT=1` repacks the newest run in place rather than starting a new one.

### Cleanup

Like BrinaOS, the script wipes its work dirs at the top of each run -- but only
after the inputs validate, so a typo'd path can't destroy the previous build.
Wiped: `work_cos`, `cos_stock`, `cos_passthru`, `stub_work`, `stubs`. Kept:
`cos_img/` (the expensive extracted-input cache) and every `out_hos/run-N/`.
Old runs are never pruned automatically -- delete them yourself; each holds
~6 GB of images plus an 11 GB super.

Overridable: `COS` (ColorOS IMAGES dir), `DONOR` (donor images), `WORK`, `OUT`, `SLOT`.

    ./vet_donor.sh <donor.zip>    # check a donor BEFORE a full build

## Flash (from Windows — WSL has no USB)

    windows/flash-op9p.ps1 -Super <out_hos\super.img> -FwDir <ColorOS IMAGES> -Slot b

Add `-SuperOnly` **only** when the device already carries a matching boot chain.
`windows/capture.sh` pulls logcat, crash buffer, `avc: denied` and tombstones
from a device stuck in a bootloop.

## Two things that will bite you

**1. The boot chain must match the firmware already on the device.**
`abl`, `tz`, `hyp`, `keymaster` and friends refuse fastboot writes
("Flashing is not allowed for Critical Partitions"), and `flashing unlock_critical`
is a no-op. So `boot`/`dtbo`/`vendor_boot`/`vbmeta`/`super` must all come from the
same build as that fixed firmware. A mismatch gives splash → fastboot and looks
exactly like an AVB rejection. Check what the phone actually runs before flashing.
Tell-tale: OOS14 `dtbo` is 25.1 MB, ColorOS 16 `dtbo` is 4.79 MB.

**2. `ro.product.cpu.abilist32` must be empty** (`port.py:apply_zygote_abi_fix`).
The vendor advertises 32-bit ABIs but `ro.zygote=zygote64` starts only one zygote,
so `/dev/socket/zygote_secondary` never exists. If the donor leaves
`ro.system.product.cpu.abilist32` empty the vendor's value wins, and `system_server`
spins forever on `Got error connecting to zygote ... No such file or directory` —
bootanimation restarts every few seconds, kernel still up. An empty `abilist32`
is the fix, not the bug; do not copy 32-bit values from a CN donor.

Not the problem, both ruled out with evidence: SELinux (enforcing, zero denials)
and VNDK (the donor already ships `com.android.vndk.v30.apex`).

## Layout

    port.py           donor system side + stock vendor/odm -> 5 EROFS images
                      applies the ABI fix and (default) ro.debuggable=1
    make_rom.sh       one-command driver: port -> my_stock skeleton -> super
    build_super.sh    lpmake packer (OP9P geometry, virtual A/B, 11190403072 B)
    verify_super.py   parse and sanity-check LP metadata
    vet_donor.sh      donor triage: 32-bit runtime, VNDK apexes, hwservicemanager
    fixes/            build.prop fragments (only system.build.prop is wired)
    RES/              optional overlays copied into the ported tree
    lib/ bin/ tools/  python deps, erofs tools, lpmake

`my_*` partitions are `first_stage_mount` **without** `nofail`, so every one must
exist. `my_stock` is rebuilt as a skeleton (2.8 GB → ~221 KB) because the port
does not otherwise fit in super; its `build.prop`/`etc`/`applist` are kept.

`--no-debuggable` ships authenticated adb. Leave it on while porting: flashing
wipes userdata, so there is no adb key and a boot failure is otherwise blind.
