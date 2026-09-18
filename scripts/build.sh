#!/bin/bash
# Construit build/moleCleaner.app sans Xcode (swiftc des Command Line Tools suffit).
# Usage : scripts/build.sh [--universal] [--install]
#   --universal : binaire Apple Silicon + Intel (pour distribuer à un autre Mac)
#   --install   : copie l'app dans /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/moleCleaner.app"
BIN="$APP/Contents/MacOS/moleCleaner"
VERSION="0.1.0"
INSTALL=false
UNIVERSAL=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --universal) UNIVERSAL=true ;;
        *)
            echo "Option inconnue : $arg" >&2
            echo "Usage : scripts/build.sh [--universal] [--install]" >&2
            exit 1
            ;;
    esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' -print0)

compile() { # $1 = architecture, $2 = fichier de sortie
    swiftc -O -parse-as-library -swift-version 5 -target "$1-apple-macos14.0" -o "$2" "${SOURCES[@]}"
}

if $UNIVERSAL; then
    echo "→ Compilation universelle (arm64 + x86_64)…"
    compile arm64 build/mc-arm64
    compile x86_64 build/mc-x86_64
    lipo -create build/mc-arm64 build/mc-x86_64 -output "$BIN"
    rm -f build/mc-arm64 build/mc-x86_64
else
    ARCH="$(uname -m)"
    echo "→ Compilation ($ARCH)…"
    compile "$ARCH" "$BIN"
fi

ICON_VARIANT="${ICON_VARIANT:-a}"
if [ ! -f build/AppIcon.icns ] \
    || [ scripts/make-icon.swift -nt build/AppIcon.icns ] \
    || [ scripts/mole-mark.png -nt build/AppIcon.icns ]; then
    echo "→ Génération de l'icône (variante $ICON_VARIANT)…"
    swiftc -O scripts/make-icon.swift -o build/make-icon
    rm -rf build/AppIcon.iconset
    build/make-icon iconset build/AppIcon.iconset "$ICON_VARIANT"
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>moleCleaner</string>
    <key>CFBundleDisplayName</key><string>moleCleaner</string>
    <key>CFBundleIdentifier</key><string>app.molecleaner.mac</string>
    <key>CFBundleExecutable</key><string>moleCleaner</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>fr</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "→ Signature ad hoc…"
codesign --force --sign - "$APP"

if $INSTALL; then
    rm -rf /Applications/moleCleaner.app
    cp -R "$APP" /Applications/
    echo "✓ Installé dans /Applications/moleCleaner.app"
else
    echo "✓ $APP"
fi
