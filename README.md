# DynamicStage — phone-fit test builds

Phone-only stage fill for Dynamic Stage: **stage card size stays fixed**; only the Phone UI scales to fill the card (no side letterboxing).

## Sileo source

In Sileo → **Sources** → **+**, add:

```
https://geegeekoby.github.io/newstage/
```

Served by GitHub Pages from the `docs/` folder on `main` (static apt repo: `Release`, `Packages`, `Packages.gz`, `Packages.bz2`, `debs/`). Newest package: **4.5.640**; 4.5.636–4.5.639 are listed too so you can downgrade.

To publish a new build: drop the `.deb` in `packages/`, run `tools/publish_pages.sh`, commit, push.

## Latest package

**4.5.640** — dial pad lift is wired after fill-scale (earlier builds had the lift code but it never ran). Dial pad sits ~110pt above the quick bar; typed-number field nudged slightly; dial scale 0.82.

Install the `.deb` from the repo root or `packages/` (Filza / Sileo / scp).

## Versions in this repo

- `com.recreated.dynamicstage_4.5.640_iphoneos-arm64.deb` (current)
- 4.5.636–4.5.639 also under `packages/` and often at repo root for quick download

Fuller DynamicStage history: Origin `uniqu3-nam3/CursorRepo`.
