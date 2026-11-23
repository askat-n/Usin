#!/bin/zsh
# Упаковать Usin.app в установочный образ: окно с Usin, ярлыком «Программы» и стрелкой между ними.
#   Scripts/make-dmg.sh path/to/Usin.app path/to/Usin-0.6.0.dmg
# Только встроенные средства macOS: hdiutil собирает образ, Finder расставляет значки и фон.
# Если Finder не ответил — образ всё равно годится, просто без фона.
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
# Finder находит том по имени, поэтому подключаем образ в /Volumes.
MOUNT="/Volumes/$VOLNAME-$$"
hdiutil attach "$WORK/rw.dmg" -mountpoint "$MOUNT" -noautoopen -quiet
DISK="$VOLNAME"
if ! timeout 20 osascript <<APPLESCRIPT >/dev/null 2>&1; then
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 160, 800, 588}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.png"
        set position of item "${APP:t}" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    echo "Finder не расставил значки — образ будет без фона."
fi
chflags hidden "$MOUNT/.background" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "$DMG"
