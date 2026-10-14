/* mkraster: write a CUPS raster stream the way macOS's cgpdftoraster would,
 * using the PPD's own setpagedevice code (cupsRasterInterpretPPD).
 * usage: mkraster PPD "options" pattern pages > out.ras
 * pattern: text | dense | blank | grid | noise
 * Also writes the expected 1-bit page bitmaps to out.ras.pN.pbm-like raw files. */
#include <cups/cups.h>
#include <cups/ppd.h>
#include <cups/raster.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned rnd = 12345;
static unsigned rnd_next(void) { rnd = rnd * 1103515245u + 12345u; return rnd >> 8; }

int main(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage\n"); return 1; }
    ppd_file_t *ppd = ppdOpenFile(argv[1]);
    if (!ppd) { fprintf(stderr, "ppd\n"); return 1; }
    cups_option_t *opts = NULL;
    int nopts = cupsParseOptions(argv[2], 0, &opts);
    ppdMarkDefaults(ppd);
    cupsMarkOptions(ppd, nopts, opts);
    const char *pat = argv[3];
    int pages = atoi(argv[4]);
    cups_page_header2_t h;
    if (cupsRasterInterpretPPD(&h, ppd, nopts, opts, NULL)) {
        fprintf(stderr, "interpret: %s\n", cupsRasterErrorString()); return 1;
    }
    cups_raster_t *r = cupsRasterOpen(1, CUPS_RASTER_WRITE);
    unsigned bits1 = (h.cupsWidth + 7) / 8;
    unsigned char *line = malloc(h.cupsBytesPerLine > bits1 ? h.cupsBytesPerLine : bits1);
    unsigned char *gray = malloc(h.cupsBytesPerLine);
    unsigned bpl1 = h.cupsBitsPerColor == 8 ? bits1 : h.cupsBytesPerLine;
    fprintf(stderr, "raster %ux%u bpl=%u bpc=%u cs=%u comp=%u res=%u pagesize=%.0fx%.0f\n",
            h.cupsWidth, h.cupsHeight, h.cupsBytesPerLine, h.cupsBitsPerColor,
            h.cupsColorSpace, h.cupsCompression, h.HWResolution[0],
            (double)h.PageSize[0], (double)h.PageSize[1]);
    for (int p = 0; p < pages; p++) {
        char fn[256]; snprintf(fn, sizeof fn, "%s.p%d", argv[5] ? argv[5] : "expected", p + 1);
        FILE *ef = fopen(fn, "wb");
        cupsRasterWriteHeader2(r, &h);
        for (unsigned y = 0; y < h.cupsHeight; y++) {
            memset(line, 0, bpl1);
            if (!strcmp(pat, "text")) {
                /* rows of "glyph" blocks with gaps, like lines of text */
                if ((y / 60) % 2 == 0 && y > 300 && y < h.cupsHeight - 300)
                    for (unsigned x = 40; x < bpl1 - 40; x++)
                        line[x] = ((x / 3 + y / 7 + p) % 5) ? (unsigned char)(rnd_next() & 0x7e) : 0;
            } else if (!strcmp(pat, "dense")) {
                for (unsigned x = 0; x < bpl1; x++)
                    line[x] = (unsigned char)rnd_next();
            } else if (!strcmp(pat, "grid")) {
                for (unsigned x = 0; x < bpl1; x++)
                    line[x] = (y % 64 < 4) ? 0xff : ((x % 16) == 0 ? 0x80 : 0);
            } else if (!strcmp(pat, "noise")) {
                for (unsigned x = 0; x < bpl1; x++)
                    line[x] = (rnd_next() % 7 == 0) ? (unsigned char)rnd_next() : 0;
            } /* blank: all zero */
            if (h.cupsBitsPerColor == 8) {           /* 1 bit -> 8-bit gray (W: 255=white) */
                for (unsigned x = 0; x < h.cupsWidth; x++) {
                    int ink = (line[x >> 3] >> (7 - (x & 7))) & 1;
                    gray[x] = (h.cupsColorSpace == CUPS_CSPACE_W || h.cupsColorSpace == CUPS_CSPACE_SW)
                              ? (ink ? 0 : 255) : (ink ? 255 : 0);
                }
                cupsRasterWritePixels(r, gray, h.cupsBytesPerLine);
            } else
                cupsRasterWritePixels(r, line, h.cupsBytesPerLine);
            if (ef) fwrite(line, 1, bpl1, ef);
        }
        if (ef) fclose(ef);
    }
    cupsRasterClose(r);
    return 0;
}
