#!/usr/bin/env bash
# Rebuild the static Sileo repo for GitHub Pages (main branch, /docs folder).
#   Sileo source URL: https://geegeekoby.github.io/newstage/
# Usage: tools/publish_pages.sh [path/to/new.deb]
set -euo pipefail
cd "$(dirname "$0")/.."
URL="https://geegeekoby.github.io/newstage"
mkdir -p public/debs
cp -p packages/*.deb public/debs/ 2>/dev/null || true
DEB="${1:-$(ls -t packages/*.deb | head -1)}"
python3 tools/make_repo.py --deb "$DEB" --url "$URL"
node -e '
const fs=require("fs");const h=require("./api/repo.js");
function call(file){let out;const res={setHeader(){},status(){return this},send(b){out=b;return this},end(b){out=b;return this}};
h({headers:{"x-forwarded-proto":"https","x-forwarded-host":"geegeekoby.github.io/newstage"},query:{file}},res);return out;}
fs.writeFileSync("public/depiction.json",call("depiction"));
fs.writeFileSync("public/sileo-featured.json",call("featured"));'
rsync -a public/ docs/
touch docs/.nojekyll
echo "docs/ ready - commit and push main; Pages serves $URL/"
