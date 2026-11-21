#!/bin/zsh
# Выпустить новую версию Usin для Mac: собрать, упаковать в zip и выложить релиз на GitHub.
# Автообновление в приложении берёт последний релиз отсюда и ставит zip из него.
#
#   1. Подними MARKETING_VERSION в Xcode (Usin → General → Version), например 0.2.0.
#   2. Scripts/release.sh "Что нового: …"
#
# Подпись — сертификатом разработчика (Apple Development), как у самого приложения: обновление
# ставится, только если команда в подписи совпадает, и выданные macOS разрешения сохраняются.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
REPO="askat-n/Usin"

VERSION="$(xcodebuild -project Usin.xcodeproj -target Usin -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" {v = $3} END {print v}')"  # без раннего exit: иначе pipefail обрывает скрипт
[[ -n "$VERSION" ]] || { echo "Не удалось узнать версию (MARKETING_VERSION)"; exit 1; }
TAG="v$VERSION"
NOTES="${1:-Usin $VERSION}"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Релиз $TAG уже есть. Подними MARKETING_VERSION и запусти снова."
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Есть незакоммиченные изменения — сначала закоммить их, чтобы релиз совпадал с кодом."
    exit 1
fi

BUILD="$ROOT/build/release"
rm -rf "$BUILD"
xcodebuild -project Usin.xcodeproj -scheme Usin -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$BUILD/dd" \
    -allowProvisioningUpdates -quiet build

APP="$BUILD/dd/Build/Products/Release/Usin.app"
codesign --verify --strict --deep "$APP"
BUILT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUILT" == "$VERSION" ]] || { echo "Собралась версия $BUILT, а ждали $VERSION"; exit 1; }

ZIP="$BUILD/Usin-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

git push origin HEAD
gh release create "$TAG" "$ZIP" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Usin $VERSION" --notes "$NOTES"
echo "Готово: https://github.com/$REPO/releases/tag/$TAG"
