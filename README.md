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
- Drag the grabber at the top of the card up or down to move between Overlay and Split View
  after the fact. The grabber is a view of its own, above everything else on the card, so a
  drag that starts on it belongs to the card rather than to whatever is underneath - the app
  grid otherwise scrolls instead and the card never moves.
- Drag the grabber down, drag from the card's bottom-right corner, or flick the card down, to
  send it back to the corner. The app on the stage keeps running.
- Swipe up from the bottom of the card to drop the app and get the picker back; the app
  shrinks into its own plate in the grid on the way out.
- Hold a plate in the picker instead of tapping it and that app opens across the whole
  screen rather than on the stage.
- Rotate the stage a quarter turn at a time, for apps that only make sense in landscape.
- When the stage is put away with an app still on it, a small icon sits in the corner so you
  know what will come back.

**The picker**

- A search field, a grid of pinned and recently opened apps (two or three rows), and the
  full app library underneath. Typing needs the stage's window to be the key window, so it
  takes that while the stage is up and hands it straight back on the way out; the card is
  held above the keyboard for as long as the keyboard is there.
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
| `/Release` | Flat-repo release record, carrying the digests of the index being served |
| `/Packages`, `/Packages.gz` | Package index, generated per request so it can name its own host |
| `/depiction.json` | Sileo native depiction: description, features, changelog |
| `/sileo-featured.json` | Featured banner for the repo page |
| `/CydiaIcon.png` | Repo icon Sileo shows in the sources list |
| `/debs/*.deb` | The package itself |

A package's icon and depiction have to be absolute URLs, and the domain is not known when
the index is written, so `api/repo.js` composes those files from `api/package-index.json`
using the host it is answering on. That means the same output works on any domain with
nothing to edit after deploying.

`Release` is composed there too, in the same request, because it has to carry the hash of
the exact index bytes the client is about to fetch. A package manager that finds no hash for
`Packages` is entitled to ignore the index it just downloaded, and on the device that looks
identical to the repo having nothing new in it. The index is also served `no-store`: one
package, and an index that costs nothing to rebuild, so a stale cache is never worth the
version that goes missing because of it.

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
- `tools/verify_package.py` runs from the `after-package` hook and checks the finished
  `.deb` rather than trusting it: both slices present, the arm64e one marked as the new
  ptrauth ABI in the fat header and the Mach-O header, its Objective-C and CFString
  pointers signed, every slice code signed. A package this device would refuse to load
  otherwise fails silently - the tweak just never appears.
- `tools/make_resources.py` regenerates `prefs/Resources/*.png`; it needs `pillow` and
  `numpy` and is only required if you change the artwork.

## Getting an app onto the stage

The card shows the app's own live render, not a picture of it. SpringBoard already has a
thing that does this - `SBAppViewController`, which is what the app switcher and iPad
multitasking use - and that is what the stage asks for. It is a view controller you hand an
app to; it makes the scene, launches the app if it is not running, hosts its layers, and
keeps the app inside SpringBoard's own lifecycle and keyboard bookkeeping.

This matters because the first version of `springboard/DSSceneHost.m` did all of that by
hand: find the app's existing scene, and if there is none, start the app suspended and wait
for one to appear. An app that has not been opened since boot has no scene, and starting it
suspended does not make one, so nothing ever arrived and the picker came back - which is
exactly what it did on 16.5. Asking SpringBoard for an app view has none of that problem,
because making the scene is part of what it does.

Two things about it are not obvious and both are load-bearing:

- **The size has to be re-sent while the app starts.** The app view re-pins the scene to the
  whole display on every update it makes, so the stage's size is written after each one -
  last write wins. A launching app is not listening for the first second or two either, so
  the size goes out again at 0.4s, 0.9s, 1.6s, 2.6s, 4s and 6s. Without that the card stays
  black until something else happens to resize it.
- **Its asserts have to be contained.** An app view the stage made is not part of
  SpringBoard's scene layout, so when the app changes its mind about being foreground,
  SpringBoard finds a state it did not put there and asserts - and that is not an exception
  that unwinds, it is SpringBoard going down. `SBAppViewController` hooks in
  `springboard/Tweak.xm` catch it, and only for the stage's own app views. For the same
  reason nothing writes the app's lifecycle from outside any more; the app view is told to
  run the lifecycle itself, from whether its view is on screen.

If a build has no app view controller to give - the class or the scene entity is missing -
the older by-hand routes are still there behind it, and the diagnostics page says which one
answered.

## The keyboard

The keyboard is never squeezed into the card. Two keyboards are involved and they need
different answers, because they are drawn by different processes.

**The stage's own search field** uses SpringBoard's keyboard: the ordinary one, full width,
at the bottom of the display, above the card, which lifts out of its way while it is there.
The signal is `UIKeyboardWillChangeFrameNotification`, which arrives in SpringBoard for
SpringBoard's own keyboards.

That keyboard is easy to lose, and two things in the stage were taking it away.

1.4.0 asked SpringBoard's keyboard focus coordinator to point the keyboard at the staged app's
scene, on the theory that a text field inside that app needed it. It did not - the app asks for
its own keyboard, in its own process - and the request was never given back, so from the first
app staged in a session the keyboard belonged to that app's scene and the picker's search field
could not raise one again. Nothing asks for keyboard focus now.

1.4.1 asked SpringBoard to place keyboards the way it does for iPad multitasking, by marking
every staged app as able to live in a scene smaller than the display. SpringBoard took that to
mean iPad multitasking was on screen and stopped putting the keyboard up for its own text
fields at all. That flag is lifted again only for an app the user has explicitly set to iPad
mode, which is what it was there for.

What the diagnostics page records, when the search field is tapped, is whether the stage's
window is key and whether a keyboard is anywhere on the display a moment later - the difference
between a field that never asked and a keyboard that never came.

**A staged app's keyboard** is drawn by the app inside its own window. There is no setting
that moves it out of that window, and nothing about it leaves the app's process - so the only
thing that can be changed is what the app's window is.

The thing that kept the keyboard in the card for every build before 1.4.4 was in this
repository, in the per-app dylib: the window UIKit draws the keyboard in, and the rectangle
UIKit places the keyboard at the bottom of, were both clamped to the height of the card. That
was deliberate once - the keyboard was meant to live in the card - and it meant nothing
SpringBoard did with the scene could move the keyboard out of it. Those hooks now answer with
the window as the scene has it, read from the scene each time a keyboard moves rather than from
the last refresh, since the scene grows at exactly that moment and an answer one layout old is
the card's height again.

So the window is made taller than the card, by exactly the height of the keyboard the app has
raised, and the card stops clipping over that last band. The keyboard lands below the card, on
the bottom edge of the display, at the size and in the position it would have full screen; the
app lays its own content out above its own keyboard, and that content is exactly what the card
shows. The card is held up by the height of the band so it all fits, and drops back to its
resting place when the keyboard goes.

The height comes from the tweak's own dylib inside that app, and there are three things that
each, on their own, kept the keyboard in the card even once all of the above was in place.

The height has to arrive. It was sent as the shared state of a Darwin notification, which the
app writes and SpringBoard reads - and an application is sandboxed where SpringBoard is not, so
being refused that write is possible, and looks from SpringBoard exactly like an app that never
raised a keyboard. The height is now also said by *which* notification was posted, one name per
ten points, because posting is something any process may do. SpringBoard listens to all of them
and still prefers the exact figure where it can read one.

SpringBoard has to know the app can report at all. The app posts once, when it notices it is on
the stage, and that is written to the diagnostics page - an app whose dylib never loaded is
otherwise indistinguishable from one that loaded and saw no keyboard.

And the keyboard has to move once the window has grown. UIKit puts a keyboard at the bottom of
the window as the window was when it went up, which is the card; the window grows a moment
later. So on every scene resize the keyboard is asked to place itself again, and if it is still
sitting where the card's bottom used to be it is put on the bottom edge of the window directly,
which on a phone is where a keyboard always is.

The band belongs to the app: touches in it are passed through to the app rather than taken as
drags on the card, and the home gesture is left alone there, so leaving an app never means
putting its keyboard away first.

## Staying out of the way

A tweak in SpringBoard can leave a device that only works in safe mode, so the parts that
could do that are bounded deliberately:

- **The per-app dylib installs nothing until the app is on the stage.** Its filter is
  UIKit, so it loads into everything with a screen, but a process that is never staged
  ends up with zero patched methods - it holds one notification observer and nothing else.
  Whether a process is staged is published both to disk and as the notification's own
  state, so an app the sandbox keeps away from the file can still tell.
- **Package managers, file managers, terminals and the jailbreak apps are excluded
  outright** (`shared/DSExclusions.m`). They are what you reach for when something else is
  broken, so they are left out of the picker, out of the per-app settings list, and never
  hooked.
- **The tweak only claims touches it has a use for.** It puts no gesture of its own at the
  bottom of the screen: it waits for SpringBoard to report a pull off the bottom edge and
  takes that drag over only when it started in the stage's corner and the stage has
  something to show, so every other pull is SpringBoard's as usual. The stage window claims
  a touch only inside the card, and the system home gesture is suppressed only inside the
  card - never across the display, so a stage stuck open cannot take the way home with it.
- **SpringBoard counts its own launches.** The count goes up before any hook is installed
  and is cleared once SpringBoard has been up for six seconds. Two launches that never got
  that far and the tweak sits the next one out, so a boot loop ends in a working device with
  the tweak off rather than one that only works in safe mode. Installing any build clears
  the count, and About shows it.
- **The first-run walkthrough cannot get stuck up.** It covers the screen at alert level,
  so it marks itself as seen when it appears rather than when it finishes (a restart gets
  rid of it instead of bringing it back), a two-finger double tap dismisses it wherever the
  buttons ended up, and it leaves by itself after three minutes untouched.
- **Every call out of a hook is contained**, so private API that moved or changed shape
  degrades into the stage not opening.
- **The Settings page cannot take Settings down with it.** Settings loads this bundle into
  its own process, so every entry point the system calls into runs inside a guard, and the
  page marks itself while it is being built and clears the mark once it is on screen. A mark
  still there on the next open means the last one did not survive, and the page is rebuilt
  out of stock cells only - same settings, no header - with **Restore Full Page** to put it
  back. Installing any build clears the mark.
- **The tweak keeps its own account of what it did.** Which pull path it is using, why a pull
  was refused, what threw in the Settings page: it is all in
  Settings › Dynamic Stage › **What The Tweak Has Been Doing**, which also has a button that
  opens the stage without the gesture. On a device that cannot hand over a crash log, that
  page is the difference between a report and a guess.

## Recovery

If a build ever leaves SpringBoard unhappy, create the safe-mode flag over SSH and respring:

```bash
ssh mobile@<device> "touch /var/mobile/.dynamicstage-disabled && sbreload"
```

Every hook checks that file before doing anything, so SpringBoard comes back stock with the
package still installed. The same flag can be toggled from the About page in Settings, and
the file can be dropped with any file manager if SSH is not set up.

With no computer to hand: force restart the device (hold the side button and volume up
until it powers off, then power on). The jailbreak is gone until it is re-run, which means
no tweaks are loaded at all, and the package can be removed from Sileo before jailbreaking
again.

## Credit

The original Dynamic Stage is by [@tomt000](https://twitter.com/tomt000). This repository is
an independent reimplementation of its behaviour for personal use on a rootless jailbreak; if
you want the real thing, buy it from his repo.
