#!/usr/bin/env bash
# Publish packages/ debs into docs/ (GitHub Pages Sileo source) and push main.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN unset; built docs only, no push" >&2
fi

# Ensure newest deb is in packages/
DEB=$(ls -t packages/com.recreated.dynamicstage_*.deb 2>/dev/null | head -1 || true)
if [[ -z "$DEB" ]]; then
  echo "no deb in packages/" >&2
  exit 1
fi

# Archive into public/debs for make_repo multi-version index
mkdir -p public/debs
cp -f packages/com.recreated.dynamicstage_*.deb public/debs/ 2>/dev/null || true
cp -f "$DEB" public/debs/

python3 tools/make_repo.py --url https://geegeekoby.github.io/newstage

# Pages serves from /docs
mkdir -p docs/debs docs/assets
cp -f public/Packages public/Packages.gz public/Packages.bz2 public/Release docs/
cp -f public/CydiaIcon.png docs/ 2>/dev/null || true
cp -f public/index.html docs/ 2>/dev/null || true
cp -f public/assets/* docs/assets/ 2>/dev/null || true
# depiction / featured if present
cp -f public/depiction.json docs/ 2>/dev/null || true
cp -f public/sileo-featured.json docs/ 2>/dev/null || true
cp -f public/debs/*.deb docs/debs/
touch docs/.nojekyll

# Keep root copies of recent debs for direct download (optional convenience)
cp -f "$DEB" "./$(basename "$DEB")"
# also copy last few
for f in $(ls -t packages/com.recreated.dynamicstage_*.deb | head -6); do
  cp -f "$f" "./$(basename "$f")"
done

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "docs/ updated locally; skip push"
  exit 0
fi

# Push via temporary clone so we don't disturb local git state oddly
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/geegeekoby/newstage.git" "$WORKDIR/repo"
# Copy project tree into clone (preserve .git)
rsync -a --delete \
  --exclude .git --exclude .theos --exclude packages/*.deb \
  --exclude 'com.recreated.dynamicstage_*.deb' \
  "$ROOT/" "$WORKDIR/repo/"
# Put debs back (rsync excluded packages debs; restore from ROOT)
mkdir -p "$WORKDIR/repo/packages" "$WORKDIR/repo/docs/debs" "$WORKDIR/repo/public/debs"
cp -f "$ROOT"/packages/*.deb "$WORKDIR/repo/packages/" 2>/dev/null || true
cp -f "$ROOT"/docs/debs/*.deb "$WORKDIR/repo/docs/debs/"
cp -f "$ROOT"/public/debs/*.deb "$WORKDIR/repo/public/debs/" 2>/dev/null || true
cp -f "$ROOT"/docs/Packages "$ROOT"/docs/Packages.gz "$ROOT"/docs/Packages.bz2 "$ROOT"/docs/Release "$WORKDIR/repo/docs/"
# root-level convenience debs
cp -f "$ROOT"/com.recreated.dynamicstage_*.deb "$WORKDIR/repo/" 2>/dev/null || true
cp -f "$ROOT"/packages/*.deb "$WORKDIR/repo/" 2>/dev/null || true

cd "$WORKDIR/repo"
git config user.email "agent@local"
git config user.name "DynamicStage Agent"
git add -A
VER=$(grep '^Version:' control | awk '{print $2}')
git commit -m "DynamicStage ${VER}: dial pad lower (call/delete visible) + Sileo index" || {
  echo "nothing to commit"
  exit 0
}
git push origin HEAD:main
echo "pushed ${VER} to geegeekoby/newstage"
