#!/bin/zsh
# Упаковать Usin.app в установочный образ: окно с Usin, ярлыком «Программы» и стрелкой между ними.
#   Scripts/make-dmg.sh path/to/Usin.app path/to/Usin-0.6.0.dmg
# Только встроенные средства macOS: hdiutil собирает образ, а раскладку окна
# (значки, фон со стрелкой) задаёт .DS_Store из Scripts/dmg/ds-store.swift.
set -euo pipefail
ROOT="${0:A:h:h}"
APP="${1:A}"
DMG="${2:A}"
VOLNAME="Usin"
rm -f "$DMG"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src/.background"
ditto "$APP" "$WORK/src/${APP:t}"
ln -s /Applications "$WORK/src/Applications"
cp "$ROOT/Scripts/dmg/background.png" "$WORK/src/.background/background.png"

hdiutil create -volname "$VOLNAME" -srcfolder "$WORK/src" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$WORK/rw.dmg" -mountpoint "$MOUNT" -nobrowse -noautoopen -quiet
# Раскладку окна (значки, фон, размер) Finder читает из .DS_Store — пишем его сами.
swift "$ROOT/Scripts/dmg/ds-store.swift" "$MOUNT" "${APP:t}" >/dev/null
chflags hidden "$MOUNT/.background" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "$DMG"
