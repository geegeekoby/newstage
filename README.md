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
- Drag the grabber down, drag the card's bottom-right corner down, or flick the card down, to
  send it back to the corner. The app on the stage keeps running.
- Swipe inward from the card's bottom-right corner to drop the app and get the picker back;
  the app shrinks into its own plate in the grid on the way out. Dragging the same corner
  down puts the whole card away instead - one grip, and the direction of the first
  fourteen points decides which it is. Inward means up, left, or both at once: a thumb on
  that corner pulling into the card rolls up and left together, and asking for left alone
  meant the phone read most of those drags as putting the card away and did nothing.

  That corner is a view of its own while an app is on the stage, for the same reason the
  grabber is: a touch a hosted app receives is delivered to that app's process, and nothing
  on SpringBoard's side is ever asked about it, so a rectangle a gesture recogniser tests
  the start of a drag against works over the app grid and does nothing at all over an app.

  Leaving an app was a swipe up from the bottom of the card until 1.5.4, and it is not any
  more because that is the home gesture's movement in the home gesture's place. The card
  can refuse the system gesture inside itself but not ten points below itself, which is
  where a thumb going up from the bottom edge of an inset card starts about half the time,
  and the phone went home instead. Sideways out of a corner is nobody else's gesture.
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

- An app can launch as iPhone or as iPad. iPad mode hands it an iPad-sized canvas so it lays
  out for the wider card, with the multitasking capability flag lifted for just that app
  while it is staged.
- An app can be excluded from the stage entirely, kept out of landscape, or allowed to keep
  running in the background after the stage is dismissed.
- A shipped compatibility table covers the apps that need a specific mode out of the box.
  Since 1.5.0 that table is the only thing that sets these, because the settings page that
  edited them was a preference bundle and a preference bundle is what crashed Settings -
  see [Settings](#settings).

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
| `shared/` | Preference reading and layout constants used by both |
| `layout/` | Files copied to the device as-is: the settings page, its icon, the per-app compatibility table |
| `tools/make_resources.py` | Draws the Settings row icon; no binary assets are hand-made |
| `public/` | The hosted Sileo repo: `Release`, the `.deb`, the repo icon and the landing page |
| `api/repo.js` | Serves the package index and depiction, filling in the deployment's own host |
| `tools/make_repo.py` | Rebuilds `public/` from the newest `.deb` in `packages/` |
| `tools/serve_repo.mjs` | Serves the repo locally with the hosted routing, for testing it |

The two tweaks are separate Theos subprojects that ship in one package, because SpringBoard
and the apps need different hooks and different filters. The settings page is not code at
all - see [Settings](#settings).

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
- `ARCHS` is `arm64 arm64e`, and both slices are needed. SpringBoard on an A12 or newer
  device is arm64e, while App Store apps the per-app dylib goes into are arm64.
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
  the modern UIKit the stage uses.
- `tools/verify_package.py` runs from the `after-package` hook and checks the finished
  `.deb` rather than trusting it: both slices present, the arm64e one marked as the new
  ptrauth ABI in the fat header and the Mach-O header, its Objective-C and CFString
  pointers signed, every slice code signed. A package this device would refuse to load
  otherwise fails silently - the tweak just never appears.
- `tools/make_resources.py` regenerates the Settings row icon; it needs `pillow` and is only
  required if you change the artwork.

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

A keyboard is never drawn inside the card, and nothing about where it goes is left to the app.

No app draws its own keyboard. UIKit draws it into a scene of the keyboard's own - one scene for
the whole device, owned by the keyboard arbiter that runs inside SpringBoard - and the app's
scene is handed a stand-in layer that says "the keyboard goes here". Whoever hosts the app's
scene hosts that stand-in too, which is why a keyboard normally lands on the bottom edge of the
display: the app is full screen, so "inside the app" and "on the bottom edge of the display" are
the same rectangle.

On the stage they are nothing like the same rectangle. The card is a small panel in the corner,
so hosting the stand-in inside it draws the keyboard inside the card, shrunk to a third of its
size and clipped by the card's own corners. Every build up to 1.5.0 was arguing with that from
the app's side - growing the app's window under the keyboard, cutting a band out of the bottom of
the card, telling UIKit to lay the keyboard out against the display - and all of it could be, and
was, ignored. The keyboard stayed in the card because the card was hosting it.

So 1.5.1 stops hosting it. The decision is SpringBoard's own and it is asked as a question -
"may this view draw the keyboard layer" - which is the same question iPad multitasking answers no
to. For the stage's card, and for nothing else on the display, the answer is now no.

That makes room, and then the keyboard has to be put somewhere. The arbiter's own scene is shown
by the stage in a window the size of the display, sitting above the card, so the keyboard comes
up where every other keyboard on the phone comes up: full width, ordinary size, on the bottom
edge. The card moves up out of its way and drops back when it goes. Only the part of that window
the keyboard is actually occupying takes a touch; everything else falls through to the card and
the home screen behind it.

Three things are worth knowing about how carefully this is switched on, because a keyboard that
has been taken out of the card and then not put anywhere is worse than a keyboard in the card:

**So the layer is taken, not asked for.** Modes 1, 2 and 3 were all tried on the phone and the
keyboard's scene stayed unpresentable, which settles it: this firmware has no interest in hosting a
keyboard for a phone that is not an iPad, and nothing will present that scene no matter how it is
asked. But the keyboard is already drawn - in the card, shrunk, which is the whole complaint - and a
layer that is being drawn can be moved.

So the card is allowed its keyboard layer, and the layer is then taken out of it and put in the
stage's own window over the display. It is found by its size: the arbiter says how big the keyboard
is in display points, in the scene's own tree it is exactly that size whatever the card is doing to
it, and nothing else in a card is the full width of the display and three hundred points tall. It is
put back exactly where it was found the moment the keyboard goes away, because a borrowed keyboard
that is never returned is an app that never draws one again, and if the app draws a fresh layer while
the stage is holding one - a language switch, an accessory view - the new one is taken and the old
one goes home, so there is never a keyboard in both places.

This also makes failure harmless in a way none of the earlier attempts were. Refusing the layer first
and then failing to host it left the keyboard nowhere; allowing it and then failing to move it leaves
the keyboard in the card, badly placed but usable, which is where it was before any of this. Giving up
is per keyboard rather than for the rest of the session, and says so once.

**Mode 0 is why there was nothing to present.** With the scene found and the presenter looked for
rather than named, the answer came back one step earlier again: the keyboard's scene has no
presentation manager at all, because nothing is presenting it. The arbiter reports the keyboard in
mode 0, which is the keyboard an iPhone has always had - drawn by the app, in the app's own scene,
with a proxy layer where whoever hosts that scene can see it. `com.apple.UIKit.KeyboardManagement.hosted`
is a shell sitting there waiting to be asked for, and an iPad sharing its display between two apps is
what asks. So the stage asks: `setKeyboardScenePresentationMode:` is tried at each value until the
scene becomes presentable, half a second is allowed for a scene to start being presented across
processes, and whatever the mode was is put back if none of it helps.

If that is refused there is one more route, and it needs no permission: the proxy layer itself. The
card was told not to draw it, and the presentation of the app's scene is built with a keyboard proxy
layer manager - by the name of its own initialiser, `_initWithScene:keyboardProxyLayerManager:` - so
the layer can be taken from there and put on the display directly. It goes back by being let go of.

**The presenter is found, not named, for the same reason.** 1.5.5 moved to the iOS 16 way of putting
a scene on screen and still failed, because `createPresenterWithIdentifier:` is not on this
firmware's presentation manager and `UIScenePresenter` is not a class here at all - it is a protocol,
reached through a factory whose name has moved. So the manager is asked what it can do: every method
of it that makes something with "presenter" in the name is tried, factories first, and whichever
hands back an object owning a view is the one. The scene itself was found on the first try once it
was looked for rather than named - `com.apple.UIKit.KeyboardManagement.hosted`, sitting in the
arbiter exactly as expected - which is what made the naming the whole of the remaining problem.

It took until 1.5.5 to be shown somewhere, though, and the reason is worth keeping. A scene used to
be put on screen by asking it for a host manager and that manager for a host view, and that is what
this did. `FBSceneHostManager` does not exist on iOS 16 - not a renamed class, not a moved one, not
a class at all - so every attempt ended at "there is no keyboard scene on this build", the keyboard
was refused in the card and then shown nowhere, and the card lifted out of the way of a keyboard
that was not there. iOS 16 presents a scene instead: `uiPresentationManager`, a presenter, and that
presenter's view, which is how the stage already had the *app* on screen a few files away. Nothing
about the design was wrong; it was calling a class that had been deleted, and the survey the log
prints now is there so the next one of those is a line in a log rather than three versions.

The same goes for finding the scene. The keyboard's scene was looked up by trying the names it used
to answer to - `keyboardScene`, `scene`, an ivar called `_scene` - and on this firmware it answers
to none of them, while the arbiter plainly has one: it has `updateKeyboardSceneSettings` and a
keyboard scene presentation mode. So it is looked for rather than named, by walking what the
arbiter is holding two levels deep and taking whichever object turns out to be a scene, preferring
one whose name mentions a keyboard. Every name found goes in the log whether it is used or not.

**The class that asks the question is found, not named.** It has moved between iOS versions and
there has never been only one of them, so every class in SpringBoard and FrontBoard that answers
it is located at startup and again the first time an app is staged, in case SpringBoard opened
the framework it lives in later. If none are found, the stage does not touch the keyboard at all,
and the diagnostics page says so.

**The keyboard is only taken off the card when it can be put on the display.** Hosting the
keyboard's scene here while the card was still drawing it would be two claims on one keyboard, so
the refusal and the hosting are switched on together. If hosting fails - no keyboard scene on this
build, no host view to be had - the takeover is abandoned rather than retried, the card starts
drawing its own keyboard again, and the reason is written down.

Failing outright is not the only way to end up with no keyboard, though, and 1.5.1 found the other
one: every step can succeed and still leave nothing on screen, because a scene hands out a host
view whether or not it has a layer to put in it. On the phone that looked like the card lifting
out of the way of a keyboard that was not there, with no way to type. So the host view is checked
a beat after it goes up - a hosted layer with no context on the other end is drawing nothing - and
if there is nothing there the takeover is abandoned and the card is laid out again, which brings
the keyboard back for the keyboard that is up rather than for the next one. Which of the scenes
FrontBoard is holding could be the keyboard's is also no longer a guess: the arbiter is asked
first, and if it will not say, the scenes are searched by name and all of their names are written
down.

**Only the staged app's keyboard is moved.** The arbiter is told about every keyboard on the
device, and the stage's own search field is one of them: that keyboard is SpringBoard's, drawn in
this process, already in the right place, and left alone. Which app raised a keyboard comes from
the arbiter along with its frame, and anything that is not the app in the card is only ever used
to decide how far to lift the card.

The card is lifted for any keyboard anywhere on the display, whoever owns it, and never so far
that it leaves the top of the screen - a card lifted off the top takes the search field, the app
and every way of closing the stage with it.

Two older mistakes are worth recording, because both of them took SpringBoard's own keyboard away
rather than moving the app's.

1.4.0 asked SpringBoard's keyboard focus coordinator to point the keyboard at the staged app's
scene, on the theory that a text field inside that app needed it. It did not - the app asks for
its own keyboard, in its own process - and the request was never given back, so from the first app
staged in a session the picker's search field could not raise a keyboard again. Nothing asks for
keyboard focus now.

1.4.1 asked SpringBoard to place keyboards the way it does for iPad multitasking, by marking every
staged app as able to live in a scene smaller than the display. SpringBoard took that to mean iPad
multitasking was on screen and stopped putting the keyboard up for its own text fields at all.
That flag is now lifted only for an app the user has explicitly set to iPad mode, which is what it
was there for.

## Settings

Settings › **Dynamic Stage** is a plist. There is no preference bundle, and no code of this
tweak's runs inside Settings.

That is not a simplification for its own sake. A preference bundle is a Mach-O that Settings
loads with `dlopen`, and the arm64e slice this toolchain produces is not fixed up correctly by
the loader on an A12 or newer device: the pointers to each class's metadata are left holding
their link-time values, and the first thing the Objective-C runtime does with a newly loaded
image is read one of them. The crash report says it plainly once you know what to look for -
`EXC_BAD_ACCESS` at an address the size of a file offset, in `readClass`, under `map_images`,
under `dlopen`, with nothing of ours on the stack because nothing of ours had run yet. Every
build up to 1.4.8 took Settings down that way the moment the row was tapped, and every fix
before this one was aimed at the page's own code, which was never what was wrong.
`tools/newabi.py` gets the two injected dylibs across - they load, and they work - but it does
not get this image across, and the difference is not something this repository can see from
here.

So the page is built by Settings out of specifiers in
`layout/Library/PreferenceLoader/Preferences/DynamicStage/DynamicStage.plist`. PreferenceLoader
turns an entry with no `bundle` key into a page owned by a controller inside PreferenceLoader
itself, whose rows are that file's `items`; each row reads and writes the tweak's own
preference domain directly and posts the notification SpringBoard reloads on. Nothing of ours
is loaded, so there is nothing of ours to crash.

What this costs, and what it does not:

- Every global setting is still there: the switch, the gesture, appearance, app size, pinned
  rows, and when a stage app gets closed.
- The pages that needed code are gone with it - the per-app behaviour list, the pinned app
  picker, the diagnostics page and About. Per-app settings are still read from the same file
  and still honoured; there is no longer a screen in Settings that writes them.
- The diagnostics the About and diagnostics pages showed are still written to
  `/var/mobile/Library/Preferences/com.recreated.dynamicstage.log`, which is where to look for
  which class the keyboard was refused in and whether the keyboard's own scene could be hosted.
  Nothing in Settings can read a file any more, so the line at the top of the stage's app list
  copies that log to the clipboard.
- Settings writes through `CFPreferences`, which holds values for a while before the file on
  disk catches up, so the tweak asks `CFPreferences` first and falls back to the file. A
  setting changed in Settings takes effect on the next pull, not on the next respring.

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
- **The Settings page cannot take Settings down with it, because it is not code.** It is a
  plist Settings renders itself; see [Settings](#settings) for why that is the only version
  of it that works here.
- **The tweak keeps its own account of what it did.** Which pull path it is using, why a pull
  was refused, whether the app on the stage answered from inside itself: it is written to
  `/var/mobile/Library/Preferences/com.recreated.dynamicstage.log`, and the part that decides
  whether the keyboard can work at all is shown at the foot of the stage's app list. On a
  device that cannot hand over a crash log, that is the difference between a report and a
  guess.

## Recovery

If a build ever leaves SpringBoard unhappy, create the safe-mode flag over SSH and respring:

```bash
ssh mobile@<device> "touch /var/mobile/.dynamicstage-disabled && sbreload"
```

Every hook checks that file before doing anything, so SpringBoard comes back stock with the
package still installed. The file can be dropped with any file manager if SSH is not set up,
and switching the tweak off in Settings has the same effect from the next respring.

With no computer to hand: force restart the device (hold the side button and volume up
until it powers off, then power on). The jailbreak is gone until it is re-run, which means
no tweaks are loaded at all, and the package can be removed from Sileo before jailbreaking
again.

## Credit

The original Dynamic Stage is by [@tomt000](https://twitter.com/tomt000). This repository is
an independent reimplementation of its behaviour for personal use on a rootless jailbreak; if
you want the real thing, buy it from his repo.

## Reading a crash

A crash inside Settings leaves nothing on screen to say why, so the stage's app list shows the
last one - what it was doing, the exception, and the top of the crashing thread as image names
and offsets - and tapping it copies the whole line, so it can be pasted rather than described.
`springboard/DSCrashReports.m` decides what is worth showing, and it decides three things that
the reader would otherwise have to work out for themselves.

**Whether it is about the build that is installed.** The install script touches
`/var/mobile/Library/Preferences/com.recreated.dynamicstage.installed`, and a report older than
that file is not shown. This matters more than it sounds: the settings page took Settings down
on every build up to 1.4.8, those reports sit in `/var/mobile/Library/Logs/CrashReporter` for
days afterwards, and up to 1.5.1 the stage went on showing one for two days after the build that
fixed it - so the fix looked like it had changed nothing.

**Which image the fault is in.** A crash inside `dlopen`, `map_images` or `readClass` is not a
fault in any of the code on the stack. It is a fault in the file being opened, and the tweak
whose hook happens to be partway through the load - a phone with tweaks on it has one hooking
`dlopen` - is a bystander. So a load-time crash is reported as what it is, with the third-party
bundles the report lists named, rather than blamed on whichever image was nearest.

**Whether it is ours at all.** Red only when this tweak's own code is in the frames of the
thread that crashed, or when a load-time crash finds a leftover `DynamicStagePrefs.bundle` still
on disk from 1.4.8 - which the install script deletes, so one being there means an upgrade did
not run, and the line says where it is. Anything else is printed in grey and says whose it is.
SpringBoard's own reports are read the same way but only shown when this tweak is named in them.

Every line in that log is clipped to 400 characters, and a line is one line. That is not tidiness:
a caught UIKit exception's reason can carry a recursive dump of an entire view hierarchy inside
it, one arrived with the whole app grid in it, and since the log is a 12 KB rolling window it
pushed every other line out. What came back was thousands of cell frames and two lines of
account - the one question it exists to answer, gone, because of a message that had nothing to
say.

The stage's log - which gesture opened it, whether the keyboard could be taken out of the card,
why an app did not appear, and what this firmware's scene-hosting classes can be told about
keyboards - is written to `/var/mobile/Library/Preferences/com.recreated.dynamicstage.log`. Since
the settings page became a plist there is nothing in Settings that can read a file, so the top of
the app list has a line that copies it to the clipboard.

An offset in one of the dylibs can be turned back into a line of source with the debug build of
the same version:

```bash
llvm-symbolizer --obj=.theos/obj/debug/arm64e/DynamicStageApp.dylib 0x132ac
```

The offsets only mean anything against the build the report came from, so keep the debug output
of a release before shipping the next one.
