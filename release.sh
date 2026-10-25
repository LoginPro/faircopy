#!/bin/zsh
# Собирает FairCopy и упаковывает в оформленный DMG: build/FairCopy-<версия>.dmg.
# Нужен dmgbuild (pip install dmgbuild). Публикация: ./release.sh publish — создаёт релиз на GitHub через gh.
set -euo pipefail
cd "${0:A:h}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/FairCopy-$VERSION.dmg"
DMGBUILD="${DMGBUILD:-dmgbuild}"

./build.sh
BG=$(mktemp -d)
swift Branding/dmg-background.swift "$BG"
rm -f "$DMG"
"$DMGBUILD" -s Branding/dmg-settings.py -D app=build/FairCopy.app -D background="$BG/background.png" "FairCopy" "$DMG"
rm -rf "$BG"
# Подпись образа тем же сертификатом, что и приложение (если он есть)
SIGN_ID="${SIGN_ID:-AI Editor Local Signing}"
security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 && codesign --force --sign "$SIGN_ID" "$DMG"
shasum -a 256 "$DMG"
echo "Built $DMG"

if [[ "${1:-}" == "publish" ]]; then
  gh release create "v$VERSION" "$DMG" --title "FairCopy $VERSION" --notes-file "${NOTES:-docs/release-notes.md}"
fi
