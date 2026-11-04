#!/usr/bin/env bash
# Builds a shareable, anonymous release into ./dist:
#   dist/Mahlas.dmg, dist/Mahlas.zip, dist/SHA256SUMS.txt
# Refuses to package if the app contains anything identifying the builder.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Mahlas.app"
DIST="$ROOT/dist"

./scripts/build-app.sh

echo "› Checking for identifying information…"
needles=(
  "$USER"
  "$HOME"
  "$(id -F 2>/dev/null || true)"
  "$(git config user.name 2>/dev/null || true)"
  "$(git config user.email 2>/dev/null || true)"
  "$(scutil --get ComputerName 2>/dev/null || true)"
  "$(scutil --get LocalHostName 2>/dev/null || true)"
)
leak=0
for n in "${needles[@]}"; do
  [ ${#n} -ge 4 ] || continue
  if grep -rqaiF -- "$n" "$APP"; then
    echo "  ✗ found: \"$n\""
    grep -rlaiF -- "$n" "$APP" | sed 's/^/      /'
    leak=1
  fi
done
if [ "$leak" -ne 0 ]; then
  echo "✗ Packaging aborted: the app contains identifying information."
  exit 1
fi
echo "  ✓ clean"

echo "› Stripping extended attributes…"
xattr -cr "$APP"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "› Creating zip…"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$DIST/Mahlas.zip"

echo "› Creating dmg…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Mahlas" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DIST/Mahlas.dmg"
rm -rf "$STAGE"

( cd "$DIST" && shasum -a 256 Mahlas.dmg Mahlas.zip > SHA256SUMS.txt )

echo "✓ Release ready:"
ls -lh "$DIST" | tail -n +2 | awk '{print "   " $5 "  " $9}'
