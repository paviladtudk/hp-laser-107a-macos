#!/usr/bin/env python3
"""splcheck: decode a SpliX/HP QPDL (SPL2/3) job like the printer would and verify it.

usage: splcheck.py job.prn [expected_page_files...] [--bpl N]
Checks: PJL wrapper, page headers, band records, 0x11 decompression, checksums,
end-of-page / end-of-job records, and (optionally) pixel-exact match against the
source raster pages.
"""
import struct, sys

def dec11(p):
    us = struct.unpack("<I", p[:4])[0]
    tab = struct.unpack("<64H", p[4:132])
    o = bytearray(p[132:132 + us]); i = 132 + us; maxptr = 0
    while i < len(p):
        b = p[i]; i += 1
        if b & 0x80:
            b2 = p[i]; i += 1
            n = ((b & 0x7f) | ((b2 & 0xc0) << 1)) + 3
            ptr = tab[b2 & 0x3f]; maxptr = max(maxptr, ptr)
            if ptr > len(o) or ptr == 0:
                raise ValueError("back-reference %d beyond decoded %d" % (ptr, len(o)))
            for _ in range(n):
                o.append(o[-ptr])
        else:
            n = b + 1
            if i + n > len(p):
                raise ValueError("raw run past end")
            o += p[i:i + n]; i += n
    return bytes(o), maxptr

def parse(path):
    d = open(path, "rb").read()
    errs = []
    if not d.startswith(b"\x1b%-12345X"):
        errs.append("missing UEL at start")
    k = d.find(b"@PJL ENTER LANGUAGE")
    if k < 0:
        return None, ["no ENTER LANGUAGE"]
    k = d.find(b"\n", k) + 1
    pages = []; i = k
    while i < len(d):
        t = d[i]
        if t == 0x00:                                  # page header (17 bytes)
            h = d[i:i + 17]
            page = dict(res=h[1] * 100, copies=(h[2] << 8) | h[3], paper=h[4],
                        w300=(h[5] << 8) | h[6], h300=(h[7] << 8) | h[8], src=h[9],
                        duplex=h[11], tumble=h[12], ver=h[14], xres=h[16] * 100,
                        bands={}, maxptr=0)
            pages.append(page); i += 17
        elif t == 0x0C:                                # band
            bn = d[i + 1]; w = (d[i + 2] << 8) | d[i + 3]; hh = (d[i + 4] << 8) | d[i + 5]
            comp = d[i + 6]; sz = int.from_bytes(d[i + 7:i + 11], "big")
            body = d[i + 11:i + 11 + sz]
            if len(body) != sz:
                errs.append("band %d truncated" % bn); break
            sig, payload, cks = body[:4], body[4:-4], int.from_bytes(body[-4:], "big")
            if comp != 0x11:
                errs.append("band %d uses compression 0x%x" % (bn, comp))
            if sig != b"\xef\xcd\xab\x09":
                errs.append("band %d bad signature %s" % (bn, sig.hex()))
            if (sum(payload) + sum(sig)) & 0xffffffff != cks:
                errs.append("band %d checksum mismatch" % bn)
            try:
                out, mp = dec11(payload)
            except ValueError as e:
                errs.append("band %d: %s" % (bn, e)); out, mp = b"", 0
            if len(out) != w * hh // 8:
                errs.append("band %d decoded %d bytes, expected %d" % (bn, len(out), w * hh // 8))
            pages[-1]["bands"][bn] = (w, hh, out)
            pages[-1]["maxptr"] = max(pages[-1]["maxptr"], mp)
            i += 11 + sz
        elif t == 0x01:                                # end of page: 01 <copies hi> <copies lo>
            pages[-1]["end"] = True; i += 3
        elif t == 0x09:                                # end of job
            rest = d[i + 1:]
            if rest != b"\x1b%-12345X":
                errs.append("unexpected bytes after end-of-job: %r" % rest[:20])
            return pages, errs
        else:
            errs.append("unknown record 0x%02x at %d" % (t, i)); break
    errs.append("no end-of-job record")
    return pages, errs

def reconstruct(page):
    if not page["bands"]:
        return 0, []
    w = next(iter(page["bands"].values()))[0] // 8
    nb = max(page["bands"]) + 1
    rows = []
    for b in range(nb):
        if b in page["bands"]:
            bw, bh, out = page["bands"][b]
            # 0x11 bands are stored column-major (one byte = 8 pixels of a row,
            # 128 rows per column) and bit-inverted (1 = white)
            rows += [bytes(255 - out[x * bh + r] for x in range(w)) for r in range(bh)]
        else:
            rows += [bytes(w)] * 128
    return w, rows

def compare(page, expected_path, bpl, dx=None, dy=None):
    """Pixel-exact check of the decoded page against the source raster.
    The driver places the raster with a small constant offset and clips the
    printer's hardware margins; we find the offset, then require every
    non-margin pixel to match exactly and report how much ink was clipped."""
    exp = open(expected_path, "rb").read()
    erows = [exp[r * bpl:(r + 1) * bpl] for r in range(len(exp) // bpl)]
    w, rows = reconstruct(page)
    if not any(any(r) for r in erows):
        return "blank page OK" if not any(any(r) for r in rows) else "FAIL: expected blank"
    if dx is None:
        # find a distinctive 24-byte ink fragment from the middle of the page
        for r in range(len(erows) // 3, len(erows)):
            e = erows[r]; mid = len(e) // 2
            frag = e[mid:mid + 24]
            if sum(1 for x in frag if x) < 12:
                continue
            hits = [(o, rows[o].find(frag)) for o in range(max(0, r - 400), min(len(rows), r + 400))
                    if frag in rows[o]]
            if len(hits) == 1:
                o, pos = hits[0]; dy = o - r; dx = pos - mid
                break
        else:
            return "FAIL: could not align page"
    bad = clipped_rows = 0; inked = 0
    for r, e in enumerate(erows):
        if not any(e):
            continue
        inked += 1
        o = r + dy
        lo = max(0, -dx); hi = min(len(e), w - dx)
        if o < 0 or o >= len(rows):
            clipped_rows += 1; continue
        if e[lo:hi] != rows[o][lo + dx:hi + dx]:
            bad += 1
    extra = sum(1 for o, row in enumerate(rows) if any(row) and not (0 <= o - dy < len(erows)))
    if bad or extra:
        return "FAIL: %d rows differ, %d unexpected ink rows" % (bad, extra)
    return "pixel-exact (%d ink rows; offset dx=%d bytes dy=%d rows; %d rows in hardware margin)" % (
        inked, dx, dy, clipped_rows)

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    bpl = int(sys.argv[sys.argv.index("--bpl") + 1]) if "--bpl" in sys.argv else 0
    if bpl:
        args = [a for a in args if a != str(bpl)]
    pages, errs = parse(args[0])
    print("pages:", len(pages or []))
    for n, p in enumerate(pages or []):
        widths = sorted({v[0] for v in p["bands"].values()})
        print("  page %d: paper=%d header=%dx%d(300dpi) res=%d copies=%d duplex=%d "
              "bands=%d bandwidth=%s maxBackRef=%d end=%s" % (
              n + 1, p["paper"], p["w300"], p["h300"], p["res"], p["copies"], p["duplex"],
              len(p["bands"]), widths, p["maxptr"], p.get("end", False)))
        if len(args) > 1 + n and bpl:
            print("    ", compare(p, args[1 + n], bpl))
    print("errors:", errs if errs else "none")
