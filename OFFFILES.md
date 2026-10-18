# DynamicStage 4.5.810 switch files

Every file lives at `/var/mobile/.dynamicstage-<name>` (rootless also checks `/var/jb/var/mobile/...`). Generated from the 4.5.809 source; updated for 4.5.810.

## Rules
- `<feature>-off` turns a feature off; default is ON unless marked opt-in.
- Opt-in features need `<feature>-on` (or the named on file).
- `coreNNN-off` returns every change of build NNN to build NNN-1 (core796..core812 are live masters; older core masters are retired and forced on unless `core796-off`).
- Group switches (DS796Group): `kb-off` (keyboard model features: kb, keys, reopen, strip, caret, swipe, return, backspace, keyfocus, rekey, kbshow, kbhide, kbnan, kbown, kbmin, kbdrag, kbguard, sbkb, keep, ghost, type, leave, entry, resign, flicker, msgfit, ks, lift, src), `verbose-on` (log792, trace766, scene773, msgdiag714 are off unless this exists), `keyring-off` (keyring795), `camera-off` (4.5.809: all camera paths).
- A crash while a feature is marked "trying" latches it off (`<feature>-latched`); latch749 reports them at start.

## Feature switches read through a gate

| file | default | gate | used in | what (nearest comment) |
|---|---|---|---|---|
| `reopen782-off` | on | DS782On | app | reopen782 brings the container back instead. |
| `reopen783-off` | on | DS783On | app |  |
| `strip784-off` | on | DS784On | app | 4.5.788: opt-in |
| `entry781-off` | on | DS781On | app |  |
| `strip783-off` | on | DS783On | app | 4.5.788: opt-in |
| `strip782-off` | on | DS782On | app | 4.5.782 strip782: see the keyboard-note hook. |
| `core783-off` | on (master) | DSFeature699On | app,shared |  |
| `reopen788-off` | on | DS788On | app | the next pass (Hingis 06:47:58.100). Rule: reopen788 off, the reopen783 |
| `reopen789-off` | on | DS789On | app | Off: /var/mobile/.dynamicstage-reopen789-off (core789-off too). |
| `swipe786-off` | on | DS786On | app | Off: /var/mobile/.dynamicstage-swipe786-off |
| `swipe787-off` | on | DS787On | app | 4.5.787 swipe787: a user dismissal, so SpringBoard skips its 1 s stand-in guard. |
| `reopen790-off` | on | DS790On | app |  |
| `reopen791-off` | on | DS791On | app | still unparks next pass (51.925, 56.082, 06.666). Off: -reopen791-off. |
| `resign777-off` | on | DS777On | app | resign778 rides on resign777-off too |
| `log791-off` | on | DS791On | app,shared |  |
| `stack778become-off` | on | DS778On | app |  |
| `caret788-off` | on | DS788On | app,shared |  |
| `reopen784-off` | on | DS785On | app |  |
| `strip790-off` | on | DS790On | app |  |
| `leave781-off` | on | DS781On | app |  |
| `log792-off` | on | DS792On | app,shared |  |
| `core797-off` | on (master) | DSFeature699On | app | Off: kbcap797-off / core797-off. |
| `perf706-off` | on | DSFeature699On | shared,springboard |  |
| `trace766-off` | on | DS766On | shared | time. Off: trace766-off / core766-off. |
| `log741-off` | on | DSFeature699On | shared | whole line before it reaches the serial writer. Off: -log741-off. |
| `spam745-off` | on | DSFeature699On | shared | count rides on the next copy. Off: /var/mobile/.dynamicstage-spam745-off |
| `trace802-off` | on | DS802On | shared |  |
| `prev767-off` | on | DS767On | shared | Off: prev767-off / core767-off (latch prev767). |
| `core766-off` | on (master) | DSFeature699On | shared,springboard | 4.5.766: master core766-off returns every 766 change to 4.5.765. |
| `core767-off` | on (master) | DSFeature699On | shared | 4.5.767: master core767-off returns every 767 change to 4.5.766. |
| `core769-off` | on (master) | DSFeature699On | shared | 4.5.769: master core769-off returns every 769 change to 4.5.768. |
| `log745-off` | on | DSFeature699On | shared | be found. Off: /var/mobile/.dynamicstage-log745-off |
| `log793-off` | on | DS793On | shared,springboard | 4.5.793 log793: name who logged it (DS+ = our image offset). |
| `stamp802-off` | on | DS802On | shared | Off: stamp802-off / core802-off. |
| `battery701-off` | on | DSFeature699On | shared | ---- 4.5.701 battery701 --------------------------------------------------------- |
| `core770-off` | on (master) | DSFeature699On | shared | 4.5.770: master core770-off returns to 769. |
| `core771-off` | on (master) | DSFeature699On | shared | 4.5.771: master core771-off returns to 770. |
| `core772-off` | on (master) | DSFeature699On | shared | 4.5.772: master core772-off returns to 771. |
| `core773-off` | on (master) | DSFeature699On | shared | 4.5.773: master core773-off returns to 772. |
| `core774-off` | on (master) | DSFeature699On | shared | 4.5.774: master core774-off returns to 773. |
| `core775-off` | on (master) | DSFeature699On | shared | 4.5.775: master core775-off returns to 774. |
| `core776-off` | on (master) | DSFeature699On | shared | 4.5.776: master core776-off returns to 775. |
| `core795-off` | on (master) | DSFeature699On | shared,springboard | 4.5.795: pass795 / sig795 / keyring795 / register795; core795-off returns to 794. |
| `core794-off` | on (master) | DS794On | shared |  |
| `core799-off` | on (master) | DSFeature699On | shared | 4.5.799: master core799-off returns every 799 change to 4.5.798. |
| `core800-off` | on (master) | DSFeature699On | shared | 4.5.800: master core800-off returns every 800 change to 4.5.799. |
| `core801-off` | on (master) | DSFeature699On | shared | 4.5.801: master core801-off returns every 801 change to 4.5.800. |
| `core802-off` | on (master) | DSFeature699On | shared | 4.5.802: master core802-off returns every 802 change to 4.5.801. |
| `core803-off` | on (master) | DSFeature699On | shared,springboard | 4.5.803: master core803-off returns every 803 change to 4.5.802. |
| `core805-off` | on (master) | DSFeature699On | shared | 4.5.805: master core805-off returns every 805 change to 4.5.804. |
| `core804-off` | on (master) | DS804On | shared |  |
| `core806-off` | on (master) | DSFeature699On | shared | 4.5.806: master core806-off returns every 806 change to 4.5.805. |
| `core807-off` | on (master) | DSFeature699On | shared | 4.5.807: master core807-off returns every 807 change to 4.5.806. |
| `core808-off` | on (master) | DSFeature699On | shared | 4.5.808: master core808-off returns every 808 change to 4.5.807 |
| `core809-off` | on (master) | DSFeature699On | shared,springboard | 4.5.809: master core809-off returns every 809 change to 4.5.808 |
| `latch809-off` | on | DSFeature699On | shared | Off: latch809-off / core809-off (back to 808: no marker). |
| `core793-off` | on (master) | DS793On | shared |  |
| `core792-off` | on (master) | DS792On | shared |  |
| `core791-off` | on (master) | DS791On | shared |  |
| `core790-off` | on (master) | DS790On | shared |  |
| `core789-off` | on (master) | DS789On | shared |  |
| `core788-off` | on (master) | DS788On | shared |  |
| `core787-off` | on (master) | DS787On | shared |  |
| `core786-off` | on (master) | DS786On | shared |  |
| `core785-off` | on (master) | DS785On | shared |  |
| `core784-off` | on (master) | DS784On | shared |  |
| `caret778-off` | on | DS778On | shared | with /var/mobile/.dynamicstage-caret778-on (or with core784-off, as 783). |
| `caret790-off` | on | DS790On | shared | kept 81 + strip on every key (Hahahah 07:00:56.373). Off: -caret790-off. |
| `core782-off` | on (master) | DS782On | shared |  |
| `core781-off` | on (master) | DS781On | shared |  |
| `core780-off` | on (master) | DS780On | shared |  |
| `core778-off` | on (master) | DS778On | shared |  |
| `core779-off` | on (master) | DSFeature699On | shared | 4.5.779: master core779-off returns to 778. |
| `core777-off` | on (master) | DS777On | shared |  |
| `camera-off` | on | DSFeature699On | springboard | 808 behaviour (camera always on). |
| `cam740-off` | on | DSFeature699On | springboard | unchanged. Off: /var/mobile/.dynamicstage-cam740-off (latch). |
| `core758-off` | on (master) | DSFeature699On | springboard | Off: call758-off / core758-off (crash latch call758). |
| `call758-off` | on | DSFeature699On | springboard | Off: call758-off / core758-off (crash latch call758). |
| `core749-off` | on (master) | DSFeature699On | springboard | Off: zone749-off / core749-off (crash latch zone749). |
| `zone749-off` | on | DSFeature699On | springboard | Off: zone749-off / core749-off (crash latch zone749). |
| `medusa803-off` | on | DS803On | springboard |  |
| `medusa802-off` | on | DS802On | springboard | Off: medusa802-off / core802-off (crash latch medusa802). |
| `keep806-off` | on | DS806On | springboard | 4.5.806 keep806: the window SpringBoard already hid (end of the previous |
| `raise740-off` | on | DS809Latched | springboard | Off: /var/mobile/.dynamicstage-raise740-off. |
| `raise741-off` | on | DSFeature699On | springboard | Off: -raise741-off. |
| `core765-off` | on (master) | DSFeature699On | springboard | 4.5.788: opt-in |
| `core768-off` | on (master) | DSFeature699On | springboard |  |
| `kbvis768-off` | on | DSFeature699On | springboard |  |
| `hide772-off` | on | DS772On | springboard | hide772-off, master core772-off (crash latch hide772). |
| `why775-off` | on | DS775On | springboard | why775: log-only lines from the SpringBoard keyboard-window decision hooks. |
| `keep776-off` | on | DS776On | springboard |  |
| `why806-off` | on | DS806On | springboard | names a staged app. Off: why806-off. |
| `keep803-off` | on | DS803On | springboard | with no hand-back). Off: keep803-off / core803-off. |
| `keep802-off` | on | DS802On | springboard |  |
| `name773-off` | on | DS773On | springboard |  |
| `name774-off` | on | DS774On | springboard | 4.5.774: IMPs are signed on arm64e; strip before comparing |
| `scene773-off` | on | DS773On | springboard | scene773: FBScene -updateSettings:withTransitionContext:completion: (existing |
| `keyfocus773-off` | on | DS773On | springboard | 4.5.773 keyfocus773: up to 3 re-asserts per show, each after the |
| `rekey775-off` | on | DS775On | springboard | 4.5.775: teardown after dismissal is not a recovery |
| `edge741-off` | on | DS809Latched | springboard | card grows; the app is never covered. Off: -edge741-off (latch). |
| `beeper707-off` | on | DSFeature699On | springboard | switch, sits behind /var/mobile/.dynamicstage-beeper707-off and its crash |
| `reg799-off` | on | DS799On | springboard | Off: reg799-off or core799-off. Crash latch via DSFeature699MarkTrying("reg799"). |
| `reason800-off` | on | DS800On | springboard | Off: reason800-off or core800-off. Crash latch via DSFeature699MarkTrying("reason800"). |
| `fg800-off` | on | DS800On | springboard |  |
| `fg801-off` | on | DS801On | springboard | foreground change). Restore with fg800RestoreLiveIfNeeded (fg801 also puts |
| `core754-off` | on (master) | DSFeature699On | springboard |  |
| `log754-off` | on | DSFeature699On | springboard | 4.5.754 log754: true when this trace line differs from the last one of its |
| `core748-off` | on (master) | DSFeature699On | springboard | exempt (unchanged). Off: geo748-off / core748-off (crash latch geo748). |
| `geo748-off` | on | DSFeature699On | springboard | exempt (unchanged). Off: geo748-off / core748-off (crash latch geo748). |
| `close741-off` | on | DSFeature699On | springboard | 4.5.741 close741: the app whose card was just torn down (and its phone-size |
| `core755-off` | on (master) | DSFeature699On | springboard | Off: k755-off / core755-off (crash latch k755). |
| `k755-off` | on | DSFeature699On | springboard | Off: k755-off / core755-off (crash latch k755). |
| `keys701-off` | on | DSFeature699On | springboard | Off: /var/mobile/.dynamicstage-keys701-off. |
| `bg719-off` | on | DSFeature699On | springboard |  |
| `blackout716-off` | on | DSFeature699On | springboard | latch blackout716-trying / -crashed) = exactly 4.5.715. |
| `gest770-off` | on | DS770On | springboard | ---- 4.5.770 gest770 (log-only) ------------------------------------------------- |
| `poll805-off` | on | DS805On | springboard | Off: poll805-off (back to the 0.25 s poll). |
| `native703-off` | on | DSFeature699On | springboard | Off: /var/mobile/.dynamicstage-native703-off (crash latch native703-trying/-crashed). |
| `perf705-off` | on | DSFeature699On | springboard | change. Off: /var/mobile/.dynamicstage-perf705-off (crash latch perf705). |
| `rim731-off` | on | DS809Latched | springboard | app's edges); the grab is the band outside the card. Off: -rim731-off. |
| `core751-off` | on (master) | DSFeature699On | springboard | Off: /var/mobile/.dynamicstage-pos751-off, master core751-off (crash latch pos751). |
| `pos751-off` | on | DSFeature699On | springboard | Off: /var/mobile/.dynamicstage-pos751-off, master core751-off (crash latch pos751). |
| `core752-off` | on (master) | DSFeature699On | springboard | Finishes pos751. Master off: /var/mobile/.dynamicstage-core752-off returns to |
| `call733-off` | on | DSFeature699On | springboard | Off: /var/mobile/.dynamicstage-call733-off (per-action latch). |
| `backspace779-off` | on | DS780On | springboard | period shortcut never fires. Off: /var/mobile/.dynamicstage-backspace779-off (core780-off too). |
| `predict805-off` | on | DS805On | springboard | file predict805-off, latch predict805). SpringBoard's keyboard shows its |
| `keyring795-off` | on | DS795On | springboard | (crash latch keyring795) brings back the file. |
| `multi702-off` | on | DSFeature699On | springboard | 4.5.702 multi702: the [KEYS] / [LIFT] debug lines (with a summary of every |
| `spring755-off` | on | DSFeature699On | springboard |  |
| `lift755-off` | on | DSFeature699On | springboard |  |
| `name755-off` | on | DSFeature699On | springboard |  |
| `type755-off` | on | DSFeature699On | springboard |  |
| `focus755-off` | on | DSFeature699On | springboard |  |
| `core756-off` | on (master) | DSFeature699On | springboard | 4.5.756: each fix has its own off file and crash latch; core756-off = 4.5.755. |
| `core757-off` | on (master) | DSFeature699On | springboard | 4.5.757: master core757-off returns to 4.5.756. |
| `core759-off` | on (master) | DSFeature699On | springboard | 4.5.759: master core759-off returns to 4.5.758. |
| `lock808-off` | on | DS808On | springboard |  |
| `msg742-off` | on | DSFeature699On | springboard | Off (= 741 behaviour for Messages): /var/mobile/.dynamicstage-msg742-off. |
| `launch740-off` | on | DSFeature699On | springboard | 4.5.740 launch740: the staged app itself was opened full screen. |
| `defer719-off` | on | DSFeature699On | springboard | Off: /var/mobile/.dynamicstage-defer719-off = set it up here as before. |
| `keyfocus772-off` | on | DS772On | springboard | Never for Messages. Off: keyfocus772-off, master core772-off (latch keyfocus772). |
| `open741-off` | on | DSFeature699On | springboard | 12:07:59.435 and .840). Picker search is never skipped. Off: -open741-off. |
| `flicker788-off` | on | DS788On | springboard | every one (at most 4 per 2 s). Off: -flicker788-off. |
| `kbown731-off` | on | DSFeature699On | springboard | keys lifted Beeper 317 pt). Off: -kbown731-off. |
| `type756-off` | on | DS756On | springboard | 4.5.756 type756: a typing owner whose card was closed or minimised is |
| `typing803-off` | on | DS803On | springboard | Spotlight's own keys on a stale typing flag). Off: typing803-off. |
| `sbkb767-off` | on | DS767On | springboard | Off: sbkb767-off / core767-off (latch sbkb767). |
| `keys759-off` | on | DS759On | springboard | / phonesize684 apps so the host sits above the stage. Off: keys759-off. |
| `noise803-off` | on | DS803On | springboard | written when the state changes. Off: noise803-off. |
| `kbfocus802-on` | off (opt-in) | DS802OptIn | springboard | kbfocus802-off / core802-off and crash latch kbfocus802 still win. |
| `hide802-off` | on | DS802On | springboard | once. Off: hide802-off / core802-off. |
| `ghost745-off` | on | DSFeature699On | springboard | 4.5.745 ghost745: remember the hide; forget the old keys. |
| `kbdrag744-off` | on | DSFeature699On | springboard | cards spring back (fast743). Off: /var/mobile/.dynamicstage-kbdrag744-off |
| `kbhide744-off` | on | DSFeature699On | springboard | 4.5.744 kbhide744: re-check when the window ends; a later show cancels. |
| `msgfit757-off` | on | DS757On | springboard | 4.5.757 msgfit757: scene-fit nudge from a phone-width line (not keyboard |
| `src746-off` | on | DSFeature699On | springboard |  |
| `own757-off` | on | DS757On | springboard |  |
| `core747-off` | on (master) | DSFeature699On | springboard | Master off: /var/mobile/.dynamicstage-core747-off (crash latch core747) |
| `late766-off` | on | DS766On | springboard | 4.5.766 late766: the last app keyboard-up dropped as stale (see ks747Resolve). |
| `msg749-off` | on | DSFeature699On | springboard | handoff keep their own path. Off: msg749-off / core749-off (latch msg749). |
| `core766log-off` | on (master) | DS766On | springboard | moment of the drop. Off: core766log-off / core766-off. |
| `core750-off` | on (master) | DSFeature699On | springboard | Master off: /var/mobile/.dynamicstage-core750-off returns to 4.5.749. |
| `fold752-off` | on | DSFeature699On | springboard | Off: fold752-off, master core752-off (crash latch fold752). |
| `host754-off` | on | DSFeature699On | springboard | latch host754). (a) attaching -> live from host754Ready, re-checked every |
| `keys756-off` | on | DS756On | springboard | Off: keys756-off / core756-off (crash latch keys756). |
| `pub807-off` | on | DS807On | springboard | Off: pub807-off / core807-off. |
| `host750-off` | on | DSFeature699On | springboard |  |
| `track756-off` | on | DS756On | springboard | 4.5.756 track756: same slot state but a different app = the old app |
| `anim748-off` | on | DS809Latched | springboard |  |
| `scene748-off` | on | DSFeature699On | springboard | Off: scene748-off (crash latch scene748). |
| `kbnan754-off` | on | DSFeature699On | springboard | Off: kbnan754-off / core754-off (crash latch kbnan754). |
| `src766-off` | on | DS766On | springboard | Tagged "down", one line per app per 3 s. Off: src766-off / core766-off. |
| `lift803-off` | on | DS803On | springboard | Off: lift803-off / core803-off (then 802's 1 s rule). |
| `lift804-off` | on | DS804On | springboard | value, 22 lines for Beeper). Off: lift804-off. |
| `sync725-off` | on | DSFeature699On | springboard | Off: /var/mobile/.dynamicstage-sync725-off (per-action crash latch; kb707 |
| `fast743-off` | on | DSFeature699On | springboard |  |
| `return786-off` | on | DS786On | springboard | Off: /var/mobile/.dynamicstage-return786-off |
| `return787-off` | on | DS787On | springboard | kbdrag744). Off: /var/mobile/.dynamicstage-return787-off |
| `kbshow728-off` | on | DSFeature699On | springboard | 4.5.728: same never-reset counter |
| `msgdiag714-off` | on | DSFeature699On | springboard | (crash latch msgdiag714-trying/-crashed). |
| `heal700-off` | on | DSFeature699On | springboard | 4.5.734 call733 |
| `heal754-off` | on | DSFeature699On | springboard | Off: heal754-off / core754-off (crash latch heal754). |
| `ev766-off` | on | DS766On | springboard | changes a card. Off: ev766-off / core766-off (latch ev766). |
| `black731-off` | on | DSFeature699On | springboard | 4.5.734 call733 |
| `kbguard740-off` | on | DS809Latched | springboard | log why the keys are not showing instead. Off: -kbguard740-off. |
| `lift756-off` | on | DS756On | springboard |  |
| `blackout699-off` | on | DSFeature699On | springboard | tries again shortly, up to 4 times). Off: /var/mobile/.dynamicstage-blackout699-off. |
| `bk752-off` | on | DSFeature699On | springboard | black) and says so loudly. Off: bk752-off (log line only). |
| `pos750-off` | on | DS809Latched | springboard | ends a keyboard move in flight cleanly first. Off: pos750-off (latch). |
| `park756-off` | on | DS756On | springboard | 4.5.756 park756: the promoted card keeps ITS corner side and picture |
| `anim702-off` | on | DSFeature699On | springboard |  |
| `rimwin740-off` | on | DSFeature699On | springboard | The grab area itself is not widened. Off: -rimwin740-off. |
| `corner771-off` | on | DS771On | springboard | Off: corner771-off, master core771-off (crash latch corner771). |
| `restore726-off` | on | DSFeature699On | springboard |  |
| `pull728-off` | on | DSFeature699On | springboard |  |
| `grab733-off` | on | DSFeature699On | springboard | cannot be cancelled from SpringBoard. Off: /var/mobile/.dynamicstage-grab733-off. |
| `spam700-off` | on | DSFeature699On | springboard | 4.5.700 spam700: picked up while its minimise is still finishing: |
| `picker740-off` | on | DSFeature699On | springboard |  |
| `corner707-off` | on | DSFeature699On | springboard | 4.5.707 corner707: a stashed icon stacks above the parked ones in its |
| `flick733-off` | on | DSFeature699On | springboard | 4.5.733 flick733: start exactly where the card is drawn (no jump at release). |
| `flick727-off` | on | DSFeature699On | springboard | started: the lag at the start. With flick727 the flight starts first and |
| `drag702-off` | on | DSFeature699On | springboard | held until the finger lifts. Off: /var/mobile/.dynamicstage-drag702-off. |
| `kbmin702-off` | on | DSFeature699On | springboard |  |
| `slide728-off` | on | DSFeature699On | springboard | Only outside707/726 calls land here with slide728 on. Off: -slide728-off. |
| `stuck727-off` | on | DSFeature699On | springboard | 4.5.734 call733 |
| `loop745-off` | on | DSFeature699On | springboard | 4.5.745 loop745: the lift that was undone must not come back from the |
| `outside726-off` | on | DSFeature699On | springboard | 4.5.726 outside726: stricter. Not in the bottom 140 pt (where the home |
| `outside707-off` | on | DSFeature699On | springboard | 4.5.734 call733 |
| `kb720-off` | on | DSFeature699On | springboard | session). Off: /var/mobile/.dynamicstage-kb720-off; per-action crash latch. |
| `kb723-off` | on | DSFeature699On | springboard | kb723 may act: on, overlay, single / two-stage, nothing being built or torn |
| `ks750-off` | on | DSFeature699On | springboard | Off: ks750-off (crash latch ks750). |
| `coalesce756-off` | on | DS756On | springboard | 4.5.756 coalesce756: the full-keyboard top is remembered per app (the |
| `focus705-off` | on | DSFeature699On | springboard | (crash latch focus705-trying / -crashed) = exactly 4.5.704. |
| `three766-off` | on | DSFeature699On | springboard | one opened: latch three766) stops new hover stages. core766-off = 765. |
| `drag706-off` | on | DSFeature699On | springboard | 4.5.706 drag706: the drag state below is shared by every card / rim pan. |
| `rimname787-off` | on | DS787On | springboard |  |
| `edge740-off` | on | DS809Latched | springboard | Off: /var/mobile/.dynamicstage-edge740-off. |
| `polish706-off` | on | DSFeature699On | springboard | ---- 4.5.706 drag706 / polish706 --------------------------------------------- |
| `lift802-off` | on | DS802On | springboard | 4.5.802 lift802: the keyboard went down (arbiter off) within `window` s, or |
| `notch746-off` | on | DSFeature699On | springboard | Off: /var/mobile/.dynamicstage-notch746-off |
| `home731-off` | on | DSFeature699On | springboard | until the swipe commits: 40 pt up, or an upward release. Off: -home731-off. |
| `core798-off` | on (master) | DSFeature699On | springboard | Off: occl798-off or core798-off (back to 797), plus crash latch. |
| `occl798-off` | on | DSFeature699On | springboard | Off: occl798-off or core798-off (back to 797), plus crash latch. |
| `focus797-off` | on | DSFeature699On | springboard | 4.5.797 focus797 (logging only): every keyboard-focus diff passed to a |
| `latch749-off` | on | DSFeature699On | springboard | Off: latch749-off / core749-off. |

## Files read by explicit path

| file | first read at |
|---|---|
| `strip784-on` | app/Tweak.xm:785 |
| `strip783-on` | app/Tweak.xm:811 |
| `strip782-on` | app/Tweak.xm:858 |
| `reopen789-off` | app/Tweak.xm:901 |
| `reopen784-off` | app/Tweak.xm:912 |
| `reopen788-off` | app/Tweak.xm:920 |
| `swipe786-off` | app/Tweak.xm:963 |
| `reopen783-off` | app/Tweak.xm:1016 |
| `caret777-off` | app/Tweak.xm:1239 |
| `caret778-off` | app/Tweak.xm:1249 |
| `resign777-off` | app/Tweak.xm:1288 |
| `keyring795-off` | app/Tweak.xm:1937 |
| `core795-off` | app/Tweak.xm:1941 |
| `kbleave743-off` | app/Tweak.xm:2754 |
| `kbapp744-off` | app/Tweak.xm:2754 |
| `leave781-off` | app/Tweak.xm:2797 |
| `strip782-off` | app/Tweak.xm:6530 |
| `caret788-off` | app/Tweak.xm:7482 |
| `strip790-off` | app/Tweak.xm:7516 |
| `log793-off` | shared/DSCrashLog.m:249 |
| `core793-off` | shared/DSCrashLog.m:250 |
| `latch754-off` | shared/DSCrashLog.m:391 |
| `core754-off` | shared/DSCrashLog.m:394 |
| `sig795-off` | shared/DSCrashLog.m:427 |
| `groupd713-off` | shared/DSDiagnostics.m:377 |
| `spam745-off` | shared/DSDiagnostics.m:561 |
| `perf697-off` | shared/DSStageDebug.h:16 |
| `anim698-off` | shared/DSStageDebug.h:69 |
| `perf698-off` | shared/DSStageDebug.h:70 |
| `crash699-off` | shared/DSStageDebug.h:79 |
| `battery701-off` | shared/DSStageDebug.h:104 |
| `table794-off` | shared/DSStageDebug.m:293 |
| `core794-off` | shared/DSStageDebug.m:295 |
| `log745-off` | shared/DSStageDebug.m:690 |
| `beat756-off` | shared/DSStageDebug.m:891 |
| `caret778-on` | shared/DSStageDebug.m:1093 |
| `caret788-on` | shared/DSStageDebug.m:1102 |
| `sbcam-on` | springboard/DSAppTraceRelay.m:187 |
| `camera-off` | springboard/DSCameraArbiter.m:1653 |
| `cam740-off` | springboard/DSCameraArbiter.m:1993 |
| `raise740-off` | springboard/DSKeyboardVisibility.m:1292 |
| `keys674-off` | springboard/DSKeys674.m:21 |
| `phonesize675-off` | springboard/DSSceneHost.m:139 |
| `phonesize-off` | springboard/DSSceneHost.m:140 |
| `phonesize677-early-off` | springboard/DSSceneHost.m:221 |
| `phonesize678-width-off` | springboard/DSSceneHost.m:231 |
| `phonesize678-pregrow-off` | springboard/DSSceneHost.m:238 |
| `phonesize680-off` | springboard/DSSceneHost.m:252 |
| `phonesize683-off` | springboard/DSSceneHost.m:279 |
| `phonesize683-on` | springboard/DSSceneHost.m:293 |
| `phonesize684-off` | springboard/DSSceneHost.m:323 |
| `phonesize685-off` | springboard/DSSceneHost.m:389 |
| `phonesize686-on` | springboard/DSSceneHost.m:395 |
| `phonesize687-off` | springboard/DSSceneHost.m:453 |
| `phonesize687-on` | springboard/DSSceneHost.m:459 |
| `phonesize688-off` | springboard/DSSceneHost.m:508 |
| `phonesize689-off` | springboard/DSSceneHost.m:514 |
| `phonesize676-nudge-off` | springboard/DSSceneHost.m:810 |
| `phonesize676-hold-on` | springboard/DSSceneHost.m:816 |
| `beeper707-off` | springboard/DSSceneHost.m:967 |
| `phonesize691-off` | springboard/DSSceneHost.m:1257 |
| `phonesize694-off` | springboard/DSSceneHost.m:1287 |
| `phonesize698-off` | springboard/DSSceneHost.m:1376 |
| `phonesize695-off` | springboard/DSSceneHost.m:1464 |
| `rearm701-off` | springboard/DSSceneHost.m:1490 |
| `phonesize690-off` | springboard/DSSceneHost.m:1729 |
| `keys701-off` | springboard/DSSceneHost.m:5331 |
| `bg719-off` | springboard/DSSceneHost.m:6890 |
| `blackout716-off` | springboard/DSSceneHost.m:7656 |
| `native703-off` | springboard/DSStageContainerView.m:16 |
| `perf705-off` | springboard/DSStageContainerView.m:93 |
| `pos751-off` | springboard/DSStageContainerView.m:438 |
| `core752-off` | springboard/DSStageContainerView.m:510 |
| `call733-off` | springboard/DSStageManager.m:32 |
| `backspace779-off` | springboard/DSStageManager.m:283 |
| `predict805-on` | springboard/DSStageManager.m:297 |
| `msg742-off` | springboard/DSStageManager.m:1216 |
| `defer719-off` | springboard/DSStageManager.m:1528 |
| `keys697-off` | springboard/DSStageManager.m:2284 |
| `kbfocus802-on` | springboard/DSStageManager.m:3071 |
| `kbdrag744-off` | springboard/DSStageManager.m:3258 |
| `ghost745-off` | springboard/DSStageManager.m:3884 |
| `core747-off` | springboard/DSStageManager.m:3924 |
| `core748-off` | springboard/DSStageManager.m:4089 |
| `core750-off` | springboard/DSStageManager.m:4100 |
| `sync725-off` | springboard/DSStageManager.m:4468 |
| `return786-off` | springboard/DSStageManager.m:4482 |
| `fast743-off` | springboard/DSStageManager.m:4494 |
| `return787-off` | springboard/DSStageManager.m:4545 |
| `msgdiag714-off` | springboard/DSStageManager.m:5724 |
| `heal700-off` | springboard/DSStageManager.m:5771 |
| `keys671-on` | springboard/DSStageManager.m:6059 |
| `launch740-off` | springboard/DSStageManager.m:6394 |
| `black731-off` | springboard/DSStageManager.m:6459 |
| `kbshow728-off` | springboard/DSStageManager.m:6874 |
| `blackout699-off` | springboard/DSStageManager.m:8210 |
| `grab733-off` | springboard/DSStageManager.m:10271 |
| `anim702-off` | springboard/DSStageManager.m:12097 |
| `drag702-off` | springboard/DSStageManager.m:12441 |
| `kbmin702-off` | springboard/DSStageManager.m:12507 |
| `outside707-off` | springboard/DSStageManager.m:12672 |
| `restore726-off` | springboard/DSStageManager.m:12681 |
| `stuck727-off` | springboard/DSStageManager.m:12689 |
| `focus704-off` | springboard/DSStageManager.m:13002 |
| `kb707-off` | springboard/DSStageManager.m:13115 |
| `kb720-off` | springboard/DSStageManager.m:13132 |
| `kb723-off` | springboard/DSStageManager.m:13177 |
| `loop745-off` | springboard/DSStageManager.m:13548 |
| `corner707-off` | springboard/DSStageManager.m:13745 |
| `focus705-off` | springboard/DSStageManager.m:13768 |
| `three766-off` | springboard/DSStageManager.m:15374 |
| `edge740-off` | springboard/DSStageManager.m:15713 |
| `drag706-off` | springboard/DSStageManager.m:16236 |
| `picker740-off` | springboard/DSStageManager.m:16399 |
| `notch746-off` | springboard/DSStageManager.m:16486 |
| `core749-off` | springboard/Tweak.xm:2539 |


## 4.5.810 changes
- New: `core810-off` (810's log changes back to 809), `quiet810-off` (occl798 "ok" line written every time again, as in 809), `switch810-off` (gest770 switcher field back to "unreadable").
- Removed with their code (files are no longer read): tree765-on / tree765-off / tree766-off / tree767-off, register774-on / register774-off, strip803-off, strip804-off, kbcap797-off; log792 no longer adds the strip792 hooks (log792 itself still gates the trace window).
- New (4.5.811): `core811-off` (all 811 changes back to 810), `unpark811-off` (staged Messages: parked input container is only signalled once the box was focused, as in 810), `entry811-off` (no entry811 bar/strip position lines), `pass811-off` (no "pass811 ... no rim651 hit followed" crumb), `switch811-off` (no gest770 re-read when SBMainSwitcherWindow is the key/other window), `quiet811-off` (why806 for every app again and why775 after the kbvis768 sample has ended, as in 810).
- New (4.5.812): `core812-off` (812 back to 811), `perf812-off` (feature switches read uncached again, as in 811), `tap812-off` (a tap focuses the staged Messages box again, as in 811). Latch: tap812.
- New (4.5.813): `realkb813-on` (opt-in, Messages uses its own real keyboard), `realkb813-off`, `core813-off` (813 back to 812-1). Latch: realkb813.
- New (4.5.814): realkb814 is ON by default. `realkb814-off` (staged Messages back to the stand-in keyboard), `core814-off` (814 back to 813). Latch: realkb814.
- New (4.5.815): realkb813/814 removed (their files do nothing). `core815-off` (815 back to 812-1), `pin815-off` (strip/bar pin and hand-over/unpark), `kbrule815-off` (812-1 keyboard shift rule), `perf815-off` (815 speed-ups). Latches: pin815, kbrule815.
- New (4.5.816): `core816-off` (816 back to 815), `grow816-off` (transcript inset follows the growing reply bar), `topstay816-off` (top card moves to the keyboard again, as 815). Latches: grow816, topstay816.
- New (4.5.817): `core817-off` (817 back to 816), `picker817-off` (old picker), `search817-off` (old picker reloads the app list on every key again). Latch: picker817. Store: /var/mobile/.dynamicstage-picker817.plist (delete it to reset pins, hidden apps and suggestions).
- 4.5.818: 817 removed; `core817-off`, `picker817-off`, `search817-off` do nothing. /var/mobile/.dynamicstage-picker817.plist (if it exists) is unused and can be deleted.
- New (4.5.819): `core819-off` (819 back to 818), `picker819-off` (classic picker), `search819-off` (per-key app reload and unthrottled lookup as in 818). Latch: picker819 (crash), plus the hang latch: /var/mobile/.dynamicstage-picker819-opening left over from an earlier start writes /var/mobile/.dynamicstage-picker819-crashed (delete it to allow picker819 again). Store: /var/mobile/.dynamicstage-picker819.plist.
- 4.5.820 = 4.5.815 code: the 816-819 off files (grow816, topstay816, core816-819, picker817/819, search817/819) do nothing.
- New (4.5.821, on 820): `core821-off` (821 back to 820), `kbmin821-off` (medusa803 / keep806 act for a minimised or parked owner again, as 820), `kbback821-off` (keys756 replays the keys and lifts without retaking the assertion or checking visibility, as 820). `kb-off` also turns off kbmin821. Latches: kbmin821, kbback821.
- New (4.5.822, on 821): `core822-off` (822 back to 821), `corner822-off` (two minimised cards may again end up sharing a corner), `edge822-off` (a corner pull that starts moving down is claimed again, as 821). Latches: corner822, edge822.
- New (4.5.823, on 822): `style823-off` (the stage app picker goes back to the exact 4.5.822 look, also while running: it applies at the next picker show), `core823-off` (823 back to 822). Latch: style823 (crash), plus the hang marker /var/mobile/.dynamicstage-style823-showing: if a SpringBoard start finds it, /var/mobile/.dynamicstage-style823-crashed is written (delete it to allow style823 again).

## 4.5.824
- /var/mobile/.dynamicstage-style824-off : 823 picker look (no glass edge/accents/carousel/pill filter/entrance)
- /var/mobile/.dynamicstage-reload824-off : full app-list reload on every picker show (823 behaviour)
- /var/mobile/.dynamicstage-core824-off : both of the above
- Latch: /var/mobile/.dynamicstage-style824-crashed (written if the hang marker /var/mobile/.dynamicstage-style824-showing survives a restart). Delete to re-allow.

## 4.5.825
- /var/mobile/.dynamicstage-pin825-off : hold opens full screen (824), no pin menu
- /var/mobile/.dynamicstage-settings825-off : Settings switches/status/recents limit/hide Copy Logs ignored
- /var/mobile/.dynamicstage-core825-off : all of 825
- Latch: /var/mobile/.dynamicstage-pin825-crashed (hang marker /var/mobile/.dynamicstage-pin825-showing)

## 4.5.826
- /var/mobile/.dynamicstage-pill826-off : old notch panel (New Stage square, drag-to-open)
- /var/mobile/.dynamicstage-core826-off : all of 826 (back to 825)
- Latch: /var/mobile/.dynamicstage-pill826-crashed (hang marker /var/mobile/.dynamicstage-pill826-showing)

## 4.5.827
- /var/mobile/.dynamicstage-pilllook827-off : closed tab drawn as in 826 (no capsule)
- /var/mobile/.dynamicstage-drag827-off : no drag of + New Stage out of the pill strip
- /var/mobile/.dynamicstage-core827-off : all of 827 (back to 826)
- Latch: /var/mobile/.dynamicstage-pilllook827-crashed (hang marker /var/mobile/.dynamicstage-pilllook827-showing)

## 4.5.828
- /var/mobile/.dynamicstage-only828-off : old fallbacks back (827 rules: 8 s window, style/pin/pill off files and latches, old panel on a strip error)
- /var/mobile/.dynamicstage-sheet828-off : the stage window no longer takes every touch while the pin menu is up
- /var/mobile/.dynamicstage-bg828-off : strip as in 827 (half-based icons, on-screen icon does nothing, strip stays open)
- /var/mobile/.dynamicstage-core828-off : all of 828 (back to 827)
- Latches: only828-crashed, sheet828-crashed, bg828-crashed

## 4.5.829
- /var/mobile/.dynamicstage-keep829-off : a minimised card's app is backgrounded by SpringBoard again (828)
- /var/mobile/.dynamicstage-core829-off : all of 829 (back to 828)
- Latch: keep829-crashed

## 4.5.830
- /var/mobile/.dynamicstage-swap830-off : no swap button in the pill strip (829)
- /var/mobile/.dynamicstage-core830-off : all of 830 (back to 829)
- Latch: swap830-crashed

## 4.5.831
- /var/mobile/.dynamicstage-pref831-off : no Always Open in Top / Bottom in the hold menu, saved choices ignored (830)
- /var/mobile/.dynamicstage-core831-off : all of 831 (back to 830)
- Latch: pref831-crashed

## 4.5.832
- /var/mobile/.dynamicstage-pair832-off : no Save pair / pair tiles in the strip (831); saved pairs are kept in prefs
- /var/mobile/.dynamicstage-core832-off : all of 832 (back to 831)
- Latch: pair832-crashed

## 4.5.833
- /var/mobile/.dynamicstage-size833-off : floating card always the 832 (medium) size, no size menu
- /var/mobile/.dynamicstage-core833-off : all of 833 (back to 832)
- Latch: size833-crashed

## 4.5.834
- /var/mobile/.dynamicstage-spring834-off : minimise / restore springs as 833 (damping 0.86 / 0.85)
- /var/mobile/.dynamicstage-look834-off : corner icon without outline, card shadow as 833
- /var/mobile/.dynamicstage-haptic834-off : no haptics for strip minimise / swap / size change (833)
- /var/mobile/.dynamicstage-core834-off : all of 834 (back to 833)
- Latches: spring834-crashed, look834-crashed, haptic834-crashed

## 4.5.835
- /var/mobile/.dynamicstage-pillshow835-off : stage window scene choice as 834
- /var/mobile/.dynamicstage-core835-off : all of 835 (back to 834)
- Latch: pillshow835-crashed

## 4.5.836
- /var/mobile/.dynamicstage-sideload836-off : picker leaves jailbreak / TrollStore apps out (835)
- /var/mobile/.dynamicstage-core836-off : all of 836 (back to 835)
- Latch: sideload836-crashed

## 4.5.837
- /var/mobile/.dynamicstage-hold837-off : holding the closed pill does nothing (836)
- /var/mobile/.dynamicstage-core837-off : all of 837 (back to 836)
- Latch: hold837-crashed
