#!/bin/zsh
# Builds Prune.app and packages it as build/macPrune.dmg (drag to Applications).
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build-app.sh
STAGE=build/dmg
rm -rf "$STAGE" build/macPrune.dmg
mkdir -p "$STAGE"
cp -R build/Prune.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname macPrune -srcfolder "$STAGE" -ov -format UDZO build/macPrune.dmg
rm -rf "$STAGE"
echo "Built build/macPrune.dmg"
