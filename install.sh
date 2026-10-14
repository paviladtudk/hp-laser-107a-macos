#!/bin/bash
# HP Laser 107a native macOS driver - installer
#
#   ./install.sh
#
# What it installs (and nothing else):
#   /Library/Printers/HP107a/rastertoqpdl   print filter (SpliX, current upstream + HP job header)
#   /Library/Printers/HP107a/hp107a.ppd     printer description (HP Laser 10x Series, A4 default)
#   /usr/libexec/cups/backend/hp107a        USB transport (IOKit; forces the classic print mode)
#   printer queue "HP_Laser_107a"
# and turns off macOS's IPP-over-USB bridge for this printer (it silently eats print jobs).
# Everything is removed again by uninstall.sh.

set -u
cd "$(dirname "$0")"
PKG="$PWD"
BUILD="$PKG/build"
LOG="$PKG/install-log.txt"
exec > >(tee "$LOG") 2>&1

say()  { printf "\n== %s\n" "$*"; }
die()  { printf "\n!! %s\n!! Nothing else was changed. Log: %s\n" "$*" "$LOG"; exit 1; }

[ "$(uname)" = "Darwin" ] || die "This installer is for macOS."
xcode-select -p >/dev/null 2>&1 || die "Apple command line tools missing: run  xcode-select --install"

say "1/6  Building the print filter (about 1 minute)"
rm -rf "$BUILD"; mkdir -p "$BUILD"
for f in splix/src/*.cpp; do
  case "$f" in *pstoqpdl.cpp) continue;; esac
  clang++ -std=gnu++11 -O2 -w -DTHREADS=2 -DCACHESIZE=30 -DDISABLE_JBIG \
          -Isplix/include -c "$f" -o "$BUILD/$(basename "$f" .cpp).o" || die "compile failed: $f"
done
clang++ -o "$BUILD/rastertoqpdl" "$BUILD"/*.o -lcups -lpthread 2>/dev/null \
  || clang++ -o "$BUILD/rastertoqpdl" "$BUILD"/*.o -lcups -lcupsimage -lpthread \
  || die "linking the filter failed"
echo "   filter OK"

say "2/6  Building the USB transport"
clang -O2 -o "$BUILD/hp107a" hp107a-usb.c -framework IOKit -framework CoreFoundation \
      -Wno-deprecated-declarations || die "building the USB transport failed"
echo "   transport OK"

say "3/6  Removing any previous install of this driver - needs your password"
sudo -v || die "administrator password needed"
cancel -a HP_Laser_107a 2>/dev/null
sudo lpadmin -x HP_Laser_107a 2>/dev/null
sudo launchctl bootout system/org.hp107a.usb 2>/dev/null
echo "   clean"

say "4/6  Installing filter, printer description and USB transport"
sudo mkdir -p /Library/Printers/HP107a
sudo install -m 755 -o root -g wheel "$BUILD/rastertoqpdl" /Library/Printers/HP107a/rastertoqpdl
sudo install -m 644 -o root -g wheel hp107a.ppd /Library/Printers/HP107a/hp107a.ppd
sudo chown root:wheel /Library/Printers/HP107a && sudo chmod 755 /Library/Printers/HP107a
if sudo install -m 700 -o root -g wheel "$BUILD/hp107a" /usr/libexec/cups/backend/hp107a; then
  URI="hp107a:/"
  echo "   USB transport installed as a CUPS backend"
else
  # Fallback (only if macOS refuses the backend folder): run the same program as a
  # small background service that CUPS hands jobs to over 127.0.0.1:9108.
  echo "   backend folder not writable - using the background-service fallback"
  sudo install -m 755 -o root -g wheel "$BUILD/hp107a" /Library/Printers/HP107a/hp107a-usb
  sudo tee /Library/LaunchDaemons/org.hp107a.usb.plist >/dev/null <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.hp107a.usb</string>
  <key>ProgramArguments</key><array><string>/Library/Printers/HP107a/hp107a-usb</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
</dict></plist>
PL
  sudo chown root:wheel /Library/LaunchDaemons/org.hp107a.usb.plist
  sudo chmod 644 /Library/LaunchDaemons/org.hp107a.usb.plist
  sudo launchctl bootstrap system /Library/LaunchDaemons/org.hp107a.usb.plist
  URI="socket://127.0.0.1:9108"
fi

say "5/6  Turning off macOS's IPP-over-USB bridge for this printer"
sudo bash tools/disable-ippusb.sh || true

say "6/6  Creating the printer"
sudo lpadmin -p HP_Laser_107a -E -v "$URI" -P /Library/Printers/HP107a/hp107a.ppd \
     -D "HP Laser 107a" -L "USB" -o printer-is-shared=false -o PageSize=A4 \
     || die "creating the printer queue failed"
sudo cupsenable HP_Laser_107a; sudo cupsaccept HP_Laser_107a
lpoptions -d HP_Laser_107a >/dev/null
echo "   connection: $(lpstat -v HP_Laser_107a)"

say "Done. 'HP Laser 107a' is ready in every app (Cmd-P)."
echo "Test page:  lp -d HP_Laser_107a $PKG/tests/testpage.pdf"
echo "Diagnose:   bash $PKG/diagnose.sh"
echo "Remove all: bash $PKG/uninstall.sh"
