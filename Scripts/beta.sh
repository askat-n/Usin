#!/bin/zsh
# «Usin Beta» — тестовая сборка из текущего кода, которую запускает Claude, пока работает над Usin.
# Своё имя, свой идентификатор (com.askatbek.usin.beta), свои настройки и своя папка данных
# (Application Support/Usin Beta): настоящие заметки и установленный Usin она не трогает.
# Пока открыт настоящий Usin, инструменты беты (горячие клавиши, чёлка, буфер) ждут, чтобы не сработать дважды.
#
#   Scripts/beta.sh          собрать и открыть (уже открытую — перезапустить)
#   Scripts/beta.sh stop     закрыть (так делает хук SessionEnd, когда Claude отключается)
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/build/beta"
BETA="$BUILD/Usin Beta.app"
BETA_ID="com.askatbek.usin.beta"

stop() {
    local pids
    pids=(${(f)"$(pgrep -f "$BETA/Contents/MacOS/" 2>/dev/null || true)"})
    [[ ${#pids} -gt 0 && -n "${pids[1]}" ]] || return 0
    kill -TERM $pids 2>/dev/null || true
    for _ in {1..25}; do pgrep -f "$BETA/Contents/MacOS/" >/dev/null || return 0; sleep 0.2; done
    kill -KILL $pids 2>/dev/null || true
}

if [[ "${1:-}" == "stop" ]]; then
    stop
    exit 0
fi

cd "$ROOT"
mkdir -p "$BUILD"
echo "Сборка Usin Beta…"
if ! xcodebuild -project Usin.xcodeproj -scheme Usin -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$BUILD/dd" \
    -allowProvisioningUpdates build > "$BUILD/build.log" 2>&1; then
    grep -E "error:" "$BUILD/build.log" | head -20
    echo "Сборка не удалась, полный журнал: $BUILD/build.log"
    exit 1
fi

stop
rm -rf "$BETA"
ditto "$BUILD/dd/Build/Products/Release/Usin.app" "$BETA"
PLIST="$BETA/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BETA_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Usin Beta" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Usin Beta" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Usin Beta" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Usin Beta" "$PLIST"

# Info.plist изменился — подписываем заново тем же сертификатом и с теми же правами.
IDENTITY="$(codesign -dvv "$BETA" 2>&1 | awk -F= '/^Authority=/ && !n++ {print $2}')"
codesign -d --entitlements - --xml "$BETA" > "$BUILD/entitlements.plist" 2>/dev/null || true
if [[ -s "$BUILD/entitlements.plist" ]]; then
    codesign --force --sign "$IDENTITY" --entitlements "$BUILD/entitlements.plist" --timestamp=none "$BETA"
else
    codesign --force --sign "$IDENTITY" --timestamp=none "$BETA"
fi
codesign --verify --strict "$BETA"

open "$BETA"
echo "Usin Beta открыта: $BETA"
