#!/usr/bin/env python3
"""Parse and validate an Android LP (super) image's metadata."""
import struct, sys

GEOM_MAGIC, HDR_MAGIC = 0x616C4467, 0x414C5030
VIRTUAL_AB = 0x1

def main(path):
    f = open(path, "rb")
    f.seek(4096)
    g = f.read(4096)
    magic, ssz = struct.unpack_from("<II", g, 0)
    if magic != GEOM_MAGIC:
        print("FAIL: bad geometry magic %#x" % magic); return 1
    max_sz, slots, blk = struct.unpack_from("<III", g, 8 + 32)
    print("geometry : metadata_max_size=%d  metadata_slots=%d  logical_block_size=%d"
          % (max_sz, slots, blk))

    hs = 4096 * 3            # geometry is 2 copies of 4096 after the 4096 gap
    f.seek(hs)
    h = f.read(512)
    hmagic, major, minor, hsize = struct.unpack_from("<IHHI", h, 0)
    if hmagic != HDR_MAGIC:
        print("FAIL: bad header magic %#x" % hmagic); return 1
    off = 4 + 2 + 2 + 4 + 32 + 4 + 32
    parts = struct.unpack_from("<III", h, off);      off += 12
    extents = struct.unpack_from("<III", h, off);    off += 12
    groups = struct.unpack_from("<III", h, off);     off += 12
    devs = struct.unpack_from("<III", h, off);       off += 12
    flags = struct.unpack_from("<I", h, off)[0] if (major, minor) >= (1, 2) else 0
    print("header   : v%d.%d  header_size=%d  flags=%#x%s"
          % (major, minor, hsize, flags,
             "  [VIRTUAL_AB_DEVICE]" if flags & VIRTUAL_AB else ""))
    print("tables   : partitions=%d extents=%d groups=%d block_devices=%d"
          % (parts[1], extents[1], groups[1], devs[1]))

    tbase = hs + hsize
    f.seek(tbase + parts[0])
    raw = f.read(parts[1] * parts[2])
    print("\n%-22s %-10s %-8s %s" % ("PARTITION", "ATTRS", "EXTENTS", "GROUP"))
    print("-" * 55)
    populated = 0
    for i in range(parts[1]):
        e = raw[i * parts[2]:(i + 1) * parts[2]]
        name = e[:36].split(b"\0")[0].decode()
        attrs, fei, ne, gi = struct.unpack_from("<IIII", e, 36)
        if ne: populated += 1
        print("%-22s %-10s %-8d %d" % (name, "readonly" if attrs & 1 else "none", ne, gi))
    print("-" * 55)
    print("populated (non-empty) partitions: %d of %d" % (populated, parts[1]))
    print("\nRESULT: metadata parses cleanly")
    return 0

sys.exit(main(sys.argv[1]))
