#!/bin/bash
# Collects everything needed to troubleshoot, into diagnose-report.txt (no paper used).
cd "$(dirname "$0")"
OUT="$PWD/diagnose-report.txt"
{
  echo "=== $(date)  macOS $(sw_vers -productVersion)  $(uname -m)"
  echo; echo "=== printer queue"; lpstat -l -p HP_Laser_107a 2>&1; lpstat -v 2>&1; lpstat -o 2>&1
  echo; echo "=== USB descriptor of the printer (classic vs IPP-over-USB modes)"
  if [ -x /usr/libexec/cups/backend/hp107a ]; then sudo /usr/libexec/cups/backend/hp107a probe 2>&1
  elif [ -x /Library/Printers/HP107a/hp107a-usb ]; then sudo /Library/Printers/HP107a/hp107a-usb probe 2>&1
  elif [ -x build/hp107a ]; then sudo build/hp107a probe 2>&1
  else echo "(transport not built yet)"; fi
  echo; echo "=== macOS IPP-over-USB bridge jobs (should be absent or disabled)"
  sudo launchctl list 2>/dev/null | grep -i ippusb
  sudo launchctl print-disabled system 2>/dev/null | grep -i ippusb
  pgrep -l ippusbd
  echo; echo "=== USB tree"; ioreg -p IOUSB -w0 -l 2>/dev/null | grep -i -E '"USB Product Name"|"idVendor"|"idProduct"|"USB Serial Number"' | head -20
  echo; echo "=== recent CUPS log lines for this printer"
  log show --last 30m --style compact --predicate 'process == "cupsd"' 2>/dev/null | grep -i -E "hp107a|HP_Laser_107a" | tail -60
  [ -f /private/tmp/hp107a-usb.log ] && { echo; echo "=== fallback service log"; tail -40 /private/tmp/hp107a-usb.log; }
} > "$OUT" 2>&1
echo "Saved: $OUT"
