#!/bin/bash
# Removes everything install.sh added.
cd "$(dirname "$0")"
echo "Removing the HP Laser 107a Mac driver (password needed)..."
sudo -v || exit 1
cancel -a HP_Laser_107a 2>/dev/null
sudo lpadmin -x HP_Laser_107a 2>/dev/null
sudo rm -f /usr/libexec/cups/backend/hp107a
sudo launchctl bootout system/org.hp107a.usb 2>/dev/null
sudo rm -f /Library/LaunchDaemons/org.hp107a.usb.plist
sudo rm -rf /Library/Printers/HP107a
# give macOS its IPP-over-USB bridge back
sudo bash tools/disable-ippusb.sh --undo 2>/dev/null
echo "Done. Remaining printers:"; lpstat -v 2>&1
