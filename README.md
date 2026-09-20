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
- The card is full-width, flush with the bottom of the display, and its corners trace the
  display's own corner radius, so it reads as part of the hardware.
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
- A safe-mode flag (`/var/mobile/Library/Preferences/com.recreated.dynamicstage.disabled`)
  keeps every hook out of SpringBoard on the next respring without uninstalling anything.

## Layout

| Path | What it is |
| --- | --- |
| `springboard/` | The SpringBoard tweak: stage window, scene hosting, gestures, picker UI, walkthrough |
| `app/` | A dylib injected into every UIKit app so a staged app believes in its smaller canvas |
| `prefs/` | The Settings bundle |
| `shared/` | Preference reading and layout constants used by all three |
| `layout/` | Files copied to the device as-is, including the per-app compatibility table |
| `tools/make_resources.py` | Draws the icons, wordmark and Settings artwork; no binary assets are hand-made |

The two tweaks and the Settings bundle are separate Theos subprojects that ship in one
package, because SpringBoard and the apps need different hooks and different filters.

## Building

Theos with an iOS 16.5 SDK is needed. From a clean checkout:

```bash
export THEOS=/path/to/theos
make package
```

The `.deb` lands in `packages/`. Install it with Sileo, Zebra, or over SSH:

```bash
make package
scp packages/com.recreated.dynamicstage_*.deb mobile@<device>:/tmp/
ssh mobile@<device> "sudo dpkg -i /tmp/com.recreated.dynamicstage_*.deb && sudo sbreload"
```

To build and install in one step with the device reachable over SSH:

```bash
make package install THEOS_DEVICE_IP=<device> THEOS_DEVICE_PORT=22
```

Notes on the build:

- `THEOS_PACKAGE_SCHEME=rootless` is set in the root `Makefile`, so everything installs
  under `/var/jb` and the package architecture is `iphoneos-arm64`.
- `ARCHS` is `arm64` only. The Linux Theos toolchain emits arm64e slices with the
  pre-iOS-14 pointer-authentication ABI, which dyld refuses to load; an arm64 slice loads
  into arm64e processes such as SpringBoard without complaint. On macOS you can set
  `ARCHS="arm64 arm64e"`.
- Always run `make` from the repository root. The deployment target lives in the root
  `Makefile`, and building a subproject directly falls back to a much older iOS and fails on
  the modern UIKit the Settings bundle uses.
- `tools/make_resources.py` regenerates `prefs/Resources/*.png`; it needs `pillow` and
  `numpy` and is only required if you change the artwork.

## Recovery

If a build ever leaves SpringBoard unhappy, create the safe-mode flag over SSH and respring:

```bash
ssh mobile@<device> "touch /var/mobile/Library/Preferences/com.recreated.dynamicstage.disabled && sbreload"
```

Every hook checks that file before doing anything, so SpringBoard comes back stock with the
package still installed. The same flag can be toggled from the About page in Settings.

## Credit

The original Dynamic Stage is by [@tomt000](https://twitter.com/tomt000). This repository is
an independent reimplementation of its behaviour for personal use on a rootless jailbreak; if
you want the real thing, buy it from his repo.
