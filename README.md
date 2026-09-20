# Dynamic Stage

A recreation of tomt000's **Dynamic Stage**: pull up from the bottom-right corner of any
app and a second, live app comes in on a card at the bottom of the screen. Let go early
and it floats over what you were using; keep pulling and the app behind resizes so the two
share the display. Built for **iPhone 14 Pro Max on iOS 16.5.1 with a rootless jailbreak
(NathanLR / ElleKit)**, and it should work on any rootless arm64e device from iOS 14 up.

This is a clean-room rebuild. Nothing is copied out of the original package: the behaviour,
geometry and animation timings were derived from the tweak's own walkthrough recordings and
screenshots, and everything here is written from scratch in Objective-C, Logos and a Python
script that draws the artwork.

## What it does

**The stage**

- Pull up from the bottom-right corner of any app, the home screen or the lock screen's app
  area, and the card follows your finger the whole way.
- Release before the halfway point and the card floats over the app you were in (Overlay).
  Release past it and the app behind resizes into the top half (Split View). A haptic tap
  marks the crossover.
- Floating, the card is inset 10pt from the left, right and bottom edges, with corners
  concentric to the display's own. In Split View it goes edge to edge and takes the
  display's radius, keeping only the 10pt gap below the app above it.
- Drag the top of the card up or down to move between Overlay and Split View after the fact.
- Drag from the card's bottom-right corner, or flick the card down, to put it away. The app
  on the stage keeps running.
- Swipe up from the bottom of the card to drop the app and get the picker back; the app
  shrinks into its own plate in the grid on the way out.
- Hold a plate in the picker instead of tapping it and that app opens across the whole
  screen rather than on the stage.
- Rotate the stage a quarter turn at a time, for apps that only make sense in landscape.
- When the stage is put away with an app still on it, a small icon sits in the corner so you
  know what will come back.

**The picker**

- A search field, a grid of pinned and recently opened apps (two or three rows), and the
  full app library underneath.
- The app that is playing audio shows a live waveform on its plate.
- Light, dark, or follow-the-system appearance, over a blur that matches the system's.

**Per-app behaviour**

- Each app can be set to launch as iPhone or as iPad. iPad mode hands the app an iPad-sized
  canvas so it lays out for the wider card, with the multitasking capability flag lifted for
  just that app while it is staged.
- Apps can be excluded from the stage entirely, kept out of landscape, or allowed to keep
  running in the background after the stage is dismissed.
- A shipped compatibility table covers the apps that need a specific mode out of the box.

**Housekeeping**

- Background stage apps can be closed on dismissal, after five minutes, after ten, or never.
- A first-launch walkthrough covers all six gestures with animated demonstrations.
- A safe-mode flag (`/var/mobile/.dynamicstage-disabled`) keeps every hook out of SpringBoard
  on the next respring without uninstalling anything.

## Layout

| Path | What it is |
| --- | --- |
| `springboard/` | The SpringBoard tweak: stage window, scene hosting, gestures, picker UI, walkthrough |
| `app/` | A dylib injected into every UIKit app so a staged app believes in its smaller canvas |
| `prefs/` | The Settings bundle |
| `shared/` | Preference reading and layout constants used by all three |
| `layout/` | Files copied to the device as-is, including the per-app compatibility table |
| `tools/make_resources.py` | Draws the icons, wordmark and Settings artwork; no binary assets are hand-made |
| `public/` | The hosted Sileo repo: `Release`, the `.deb`, the repo icon and the landing page |
| `api/repo.js` | Serves the package index and depiction, filling in the deployment's own host |
| `tools/make_repo.py` | Rebuilds `public/` from the newest `.deb` in `packages/` |
| `tools/serve_repo.mjs` | Serves the repo locally with the hosted routing, for testing it |

The two tweaks and the Settings bundle are separate Theos subprojects that ship in one
package, because SpringBoard and the apps need different hooks and different filters.

## Installing

The built package is in the repository at `public/debs/`, so it can be installed either
straight off disk or from the Sileo repo this project also serves.

Over SSH, from a checkout:

```bash
scp public/debs/com.recreated.dynamicstage_*.deb mobile@<device>:/tmp/
ssh mobile@<device> "sudo dpkg -i /tmp/com.recreated.dynamicstage_*.deb && sudo sbreload"
```

Or open the `.deb` with Filza on the device and install it there.

## The Sileo repo

`public/` is a flat APT repository — the same shape as any tweak repo you would add in
Sileo — and it is deployable as-is. Deploying this project publishes it; the repo URL is
then just the deployment's root URL, which you add under Sileo › Sources › **+**. The
landing page at that URL shows the URL, an **Add to Sileo** button and a direct `.deb`
download.

What it serves:

| Route | What it is |
| --- | --- |
| `/` | Landing page, with the repo URL and the `sileo://` and `zbra://` add links |
| `/Release` | Flat-repo release record, `iphoneos-arm64` |
| `/Packages`, `/Packages.gz` | Package index, generated per request so it can name its own host |
| `/depiction.json` | Sileo native depiction: description, features, changelog |
| `/sileo-featured.json` | Featured banner for the repo page |
| `/CydiaIcon.png` | Repo icon Sileo shows in the sources list |
| `/debs/*.deb` | The package itself |

A package's icon and depiction have to be absolute URLs, and the domain is not known when
the index is written, so `api/repo.js` composes those three files from
`api/package-index.json` using the host it is answering on. That means the same output works
on any domain with nothing to edit after deploying.

After building a new `.deb`, refresh the repo and redeploy:

```bash
make package FINALPACKAGE=1
python3 tools/make_repo.py
```

To check it before deploying, serve it exactly as the hosting does and point `apt` at it:

```bash
node tools/serve_repo.mjs 43117
curl http://127.0.0.1:43117/Packages
```

Serving it on the network instead is enough to install from the device without hosting the
repo anywhere — add `http://<computer-ip>:43117/` in Sileo while it runs:

```bash
HOST=0.0.0.0 node tools/serve_repo.mjs 43117
```

Static hosting that cannot run the handler (GitHub Pages, S3) needs the URLs baked in
instead, which also writes out a static index:

```bash
python3 tools/make_repo.py --url https://repo.example.com
```

Sileo will say the repo is unsigned. That is expected: it has no GPG key, like most tweak
repos, and `[trusted=yes]` is implied for the sources Sileo adds.

## Building

Theos with an iOS 16.5 SDK is needed. From a clean checkout:

```bash
export THEOS=/path/to/theos
make package
```

The `.deb` lands in `packages/`; copy it into the repo with `python3 tools/make_repo.py` or
install it directly as above. To build and install in one step with the device reachable
over SSH:

```bash
make package install THEOS_DEVICE_IP=<device> THEOS_DEVICE_PORT=22
```

Notes on the build:

- `THEOS_PACKAGE_SCHEME=rootless` is set in the root `Makefile`, so everything installs
  under `/var/jb` and the package architecture is `iphoneos-arm64`.
- `ARCHS` is `arm64 arm64e`, and both slices are needed. The processes this hooks on an
  A12 or newer device are arm64e, and PreferenceLoader will not load an arm64 preference
  bundle on such a device, while App Store apps the per-app dylib goes into are arm64.
- The Linux toolchain compiles arm64e with the pre-iOS-14 pointer-authentication ABI,
  which iOS 14.5 and later refuse to load, and the linker changes for the new ABI were
  never open sourced. `tools/newabi.py` runs from the root `Makefile`'s `after-stage` hook
  and closes that gap: it rewrites the Objective-C pointer signing the two ABIs disagree
  on using [allemande](https://github.com/p0358/allemande), marks the slice as using the
  versioned ptrauth ABI, and re-signs. It builds allemande on first use, so a host `g++`
  with C++20 is needed once; set `ALLEMANDE=/path/to/allemande` to use your own. Building
  on macOS with Xcode 12 or newer produces new-ABI arm64e directly and the hook then does
  nothing.
- Always run `make` from the repository root. The deployment target lives in the root
  `Makefile`, and building a subproject directly falls back to a much older iOS and fails on
  the modern UIKit the Settings bundle uses.
- `tools/make_resources.py` regenerates `prefs/Resources/*.png`; it needs `pillow` and
  `numpy` and is only required if you change the artwork.

## Recovery

If a build ever leaves SpringBoard unhappy, create the safe-mode flag over SSH and respring:

```bash
ssh mobile@<device> "touch /var/mobile/.dynamicstage-disabled && sbreload"
```

Every hook checks that file before doing anything, so SpringBoard comes back stock with the
package still installed. The same flag can be toggled from the About page in Settings.

## Credit

The original Dynamic Stage is by [@tomt000](https://twitter.com/tomt000). This repository is
an independent reimplementation of its behaviour for personal use on a rootless jailbreak; if
you want the real thing, buy it from his repo.
