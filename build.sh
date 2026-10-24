#!/bin/zsh
# Собирает "FairCopy.app" одними Command Line Tools (без Xcode).
# Цель — macOS 26+: интерфейс на Liquid Glass (glassEffect, GlassEffectContainer).
set -euo pipefail
cd "${0:A:h}"

# Идентификатор (local.aieditor) и имя бинарника не меняем при переименовании:
# по ним macOS узнаёт приложение для «Универсального доступа» и Связки ключей.
APP="build/FairCopy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  -framework SwiftUI -framework Carbon -framework ServiceManagement \
  -o "$APP/Contents/MacOS/AIEditor" \
  Sources/*.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"
# Постоянный самоподписанный сертификат: требование подписи (designated requirement)
# не меняется между сборками, и macOS не сбрасывает «Универсальный доступ».
# Если сертификата нет (другой Mac) — ad-hoc подпись, доступ придётся выдавать после каждой сборки.
SIGN_ID="${SIGN_ID:-AI Editor Local Signing}" # своё имя сертификата: SIGN_ID="..." ./build.sh
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_ID" --identifier local.aieditor "$APP"
else
  echo "warning: сертификат \"$SIGN_ID\" не найден, подписываю ad-hoc"
  codesign --force --sign - --identifier local.aieditor "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p ~/Applications
  pkill -x AIEditor || true
  rm -rf ~/Applications/"AI Editor.app" ~/Applications/"FairCopy.app"  # старое имя тоже убираем
  cp -R "$APP" ~/Applications/
  open ~/Applications/"FairCopy.app"
  echo "Installed to ~/Applications"
fi
