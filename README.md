# HP Laser 107a (103 / 108) on macOS: native driver

Print to an **HP Laser 107a** (and the 103a/108a/w siblings) from any Mac app with **⌘P**,
over USB. No Windows VM, no unplugging the cable between jobs.

HP never released a macOS driver for these printers. They are rebadged **Samsung M2020-series**
lasers that speak Samsung's SPL/QPDL raster language, and they have a USB quirk that makes macOS
lose print jobs. This project combines the current open-source SpliX driver with a small USB
transport that works around that quirk.

> **Tested:** HP Laser 107a, Intel MacBook Pro (2020), macOS 26.7.1. Multiple jobs in a row,
> multi-page documents, A4.
> **Should work, but untested:** Apple Silicon Macs, HP Laser 103a/108a/108w.
> Reports welcome in Issues.

## Install

You need Apple's command line tools (`xcode-select --install`). Homebrew is **not** needed.
Connect the printer by USB, then:

```bash
git clone https://github.com/paviladtudk/hp-laser-107a-macos.git
cd hp-laser-107a-macos
./install.sh
```

It asks for your password once, builds two small programs, and adds a printer called
**"HP Laser 107a"** (A4 by default; change the paper size in the print dialog).

Test it:

```bash
lp -d HP_Laser_107a tests/testpage.pdf                          # one page: "OK"
for n in 1 2 3 4 5; do lp -d HP_Laser_107a tests/job$n.pdf; done  # five jobs: pages 1..5
lp -d HP_Laser_107a tests/three-pages.pdf                       # one 3-page job: A, B, C
```

Remove everything again with `./uninstall.sh`.

## Why the usual fixes fail

If you've tried the forum advice ("use the Samsung M2020 driver"), you've probably hit one of these:

1. **No Samsung Mac driver to download anymore**, and the old one doesn't run on current macOS.
2. **"SPL ERROR – Including Corrupted Data" / "Please use the proper driver" pages.** Older
   SpliX (2.0.1, what most guides use) sends page strips of the wrong width. This printer only
   accepts the exact band widths HP's own driver uses (4864 px for A4, 5120 for Letter). SpliX
   added them for the HP Laser 10x in 2.0.2.
3. **"Offline", every second job lost, pages only printing after you replug the cable.** The
   107a's USB port has two modes: classic printing (class 7/1/2) and **IPP-over-USB** (7/1/4).
   The IPP-over-USB mode is broken in the firmware (it answers every request with 404; see
   [OpenPrinting/ipp-usb#51](https://github.com/OpenPrinting/ipp-usb/issues/51)). macOS starts
   its `ippusbd` bridge for the printer and flips it into that mode, where ordinary print data
   is **silently dropped**. Replugging works only because the printer resets to classic mode
   when it re-enumerates.

## How it works

```
any app ─⌘P─▶ CUPS ─▶ cgpdftoraster ─▶ rastertoqpdl (SpliX) ─▶ hp107a backend ─USB─▶ printer
```

* **`splix/`**: [OpenPrinting SpliX](https://github.com/OpenPrinting/splix) at commit `7a80218`
  (HP Laser 10x band widths, 300-dpi page header, cache race fix), with one patch
  (`splix/hp107a-pjl.patch`): it sends the same PJL job header that HP's Windows driver sends
  to this printer, and drops SpliX's `@PJL DEFAULT POWERSAVE…` lines, which rewrite the
  printer's non-volatile settings on every job. Built without JBIG; this printer uses compression 0x11.
* **`hp107a-usb.c`**: a CUPS backend in C using IOKit, adapted from
  [Kuberwastaken/hp-laser-1008a-macos](https://github.com/Kuberwastaken/hp-laser-1008a-macos)
  (same Samsung engine). For every job it selects the **classic** alternate setting of the
  printer interface before writing, and sends data in 64 KB pieces. It never resets the printer
  (resetting mid-job jams the paper path). If `ippusbd` holds the port it is stopped.
* **`tools/disable-ippusb.sh`**: disables macOS's per-device IPP-over-USB bridge, only for
  HP Laser 103/107/108. `uninstall.sh` re-enables it.
* **`hp107a.ppd`**: SpliX's "HP Laser 10x Series" description, A4 default.

Installed files: `/Library/Printers/HP107a/` (filter + PPD) and `/usr/libexec/cups/backend/hp107a`.
If macOS refuses the backend folder, the installer falls back to running the same program as a
small LaunchDaemon on `127.0.0.1:9108`.

## Verification

The filter output was checked against **HP's official Linux driver** (`rastertospl` from the
Samsung/HP Unified Linux Driver 1.00.39) on identical input pages. Page headers, band widths,
compression and end-of-page/end-of-job records match. The differences are cosmetic: HP rounds
the page height down (3507 vs 3509 lines for A4), and HP applies a slight edge-thinning filter.
Every test document decodes back **pixel-exact** (A4, Letter, A5, Legal; text, dense
graphics, noise, blank; up to 12 pages). The tools are in `dev/`:
`mkraster.c` generates CUPS rasters, and `splcheck.py` decodes and verifies an SPL/QPDL job.

## Other printers (SPL/QPDL family)

The HP Laser 107a is one of about 100 printers built on Samsung's SPL/QPDL engine. The
[SpliX](https://github.com/OpenPrinting/splix) driver used here knows all of them. This
repository is **set up and tested only for the HP Laser 103/107/108**, but the list below
tells owners of related printers where they stand.

| Family | Models | Notes |
|---|---|---|
| **HP (Samsung-made)** | Laser 103a/107a/107w/108a/108w · Laser MFP 135a/135w/137fnw (13x) · Laser 1003–1008 a/w · Laser MFP 1136–1139, 1188 · LaserJet MFP M433, M436 | SPL only, no HP Mac driver. The **MFP 135a/137fnw** also has the broken IPP-over-USB mode ([ipp-usb#52](https://github.com/OpenPrinting/ipp-usb/issues/52)) and is the closest relative; the 1003–1008 are covered by [hp-laser-1008a-macos](https://github.com/Kuberwastaken/hp-laser-1008a-macos). |
| **Samsung Xpress / M** | M2020/M2022/M2026 (the original 107a), M2070, M262x/282x, M267x/287x, M283x | M20xx/M2070 are SPL only; some larger models also speak PCL. |
| **Samsung ML** | ML-1510 … ML-3560 (e.g. ML-1660, ML-1860, ML-2160/2165, ML-2525, ML-2580) | Mostly SPL only. |
| **Samsung SCX** (multifunction) | SCX-3200, 3400, 4100–4623, 5330, 5530 | |
| **Samsung CLP/CLX** (colour) | CLP-300/310/315, CLP-500–610, CLX-2160/2170/3160 | Colour uses other compression modes (JBIG); this build disables JBIG. |
| **Xerox** (Samsung-built) | Phaser 3020, 3052, 3115–3160, 3260, 3420/3425, 5500, 6100/6110 · WorkCentre 3025, 3119, 3215, 3225, PE16, PE114e | 3020/3025 are SPL only; 3260/3225 also speak PCL. |
| **Others** | Dell 1100/1110 · Lexmark X215 · Toshiba e-STUDIO 180S | |

Printers that also speak **PCL or PostScript** usually work with a generic macOS driver and
don't need this. For **SPL-only** models, adapting this repo mostly means using the matching
PPD from SpliX (`ppd/*.drv.in`) instead of `hp107a.ppd`, and checking that the printer appears
in `./diagnose.sh`. If you get another model working, please open an issue or a pull request
so it can be listed as tested.

## Troubleshooting

* Run `./diagnose.sh`. It writes `diagnose-report.txt` with the queue state, the printer's USB
  descriptor (you should see both `proto=2` and `proto=4`) and whether the IPP-over-USB
  bridge is disabled.
* **Stopped working after a macOS update?** The update may have re-enabled the bridge:
  `sudo bash tools/disable-ippusb.sh && cupsenable HP_Laser_107a`
* Using **VMware / Parallels** with the printer connected to a VM? The Mac can't reach it
  while a VM holds the USB device.
* The first page after the printer has been idle takes 10–15 s while the fuser heats up.

## Credits & licence

* [SpliX](https://github.com/OpenPrinting/splix) by Aurélien Croc and contributors; HP Laser
  10x support by ValdikSS. GPL-2.0.
* USB backend and IPP-USB script adapted from
  [hp-laser-1008a-macos](https://github.com/Kuberwastaken/hp-laser-1008a-macos). MIT
  (see `tools/LICENSE-hp-laser-1008a-macos`).
* Everything else in this repository: GPL-2.0 (see `LICENSE`).

Not affiliated with HP or Samsung. "HP" is a trademark of HP Inc.
