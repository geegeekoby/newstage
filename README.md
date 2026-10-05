# DynamicStage — phone-fit test builds

Phone-only stage fill for Dynamic Stage: **stage card size stays fixed**; only the Phone UI scales to fill the card (no side letterboxing).

## Sileo source

In Sileo → **Sources** → **+**, add:

```
https://geegeekoby.github.io/newstage/
```

Served by GitHub Pages from the `docs/` folder on `main` (static apt repo: `Release`, `Packages`, `Packages.gz`, `Packages.bz2`, `debs/`). Newest package: **4.5.641**; 4.5.636–4.5.640 are listed too so you can downgrade.

To publish a new build: drop the `.deb` in `packages/`, run `tools/publish_pages.sh`, commit, push.

## Latest package

**4.5.641** — fixes the broken / cut-off dial circles from 4.5.640. The dial pad is now scaled as one piece with a uniform transform (0.82) instead of resizing every view inside each key. Still lifted ~110pt above the quick bar so 7–8–9 clear it.

Install the `.deb` from the repo root or `packages/` (Filza / Sileo / scp).

## Versions in this repo

- `com.recreated.dynamicstage_4.5.641_iphoneos-arm64.deb` (current)
- 4.5.636–4.5.640 also under `packages/` and often at repo root for quick download

Fuller DynamicStage history: Origin `uniqu3-nam3/CursorRepo`.
