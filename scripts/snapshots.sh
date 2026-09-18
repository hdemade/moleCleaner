#!/bin/bash
# Rend chaque page de l'app hors écran et l'exporte en PNG (outil de développement).
# Usage : scripts/snapshots.sh [dossier]   (défaut : build/snapshots)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/snapshots}"
mkdir -p "$OUT" build
find Sources -name '*.swift' ! -name 'App.swift' -print0 | xargs -0 swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" scripts/snapshots/main.swift -o build/snapshots-bin
build/snapshots-bin "$OUT"
