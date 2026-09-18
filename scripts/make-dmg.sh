#!/bin/bash
# Crée un DMG d'installation : build/moleCleaner-<version>.dmg
# Usage : scripts/make-dmg.sh [--native]
#   par défaut : binaire universel (Apple Silicon + Intel)
#   --native   : uniquement l'architecture de ce Mac (plus rapide)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(grep -m1 '^VERSION=' scripts/build.sh | cut -d'"' -f2)"
BUILD_ARGS=()
[ "${1:-}" = "--native" ] || BUILD_ARGS+=(--universal)

echo "→ Construction de l'app…"
scripts/build.sh "${BUILD_ARGS[@]}"

APP="build/moleCleaner.app"
STAGE="build/dmg-stage"
DMG="build/moleCleaner-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/LISEZMOI.txt" <<'TXT'
moleCleaner
===========

Installation
------------
Glisse moleCleaner dans le dossier Applications (raccourci fourni dans cette fenêtre).

L'app a besoin de la CLI Mole pour fonctionner. Si elle est absente, moleCleaner le
détecte au lancement et propose de l'installer en un clic, avec Homebrew ou avec le
script officiel du projet. Rien à taper dans le Terminal.

Premier lancement
-----------------
L'app est signée « ad hoc », pas notariée par Apple. macOS refusera donc de l'ouvrir
d'un simple double-clic. Pour l'autoriser, une seule fois :

   clic droit sur moleCleaner dans Applications -> Ouvrir -> Ouvrir

Si macOS annonce une app « endommagée », retire la mise en quarantaine :

   xattr -dr com.apple.quarantine /Applications/moleCleaner.app

Compatibilité : macOS 14 ou plus récent, Apple Silicon et Intel.
TXT

echo "→ Création du DMG…"
hdiutil create -quiet -volname "moleCleaner" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
