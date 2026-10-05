# Cloud Agent instructions

## Ship to production (no manual Merge / Deploy clicks)

When a task is **done** (code committed, and for releases: `make package FINALPACKAGE=1` + `python3 tools/make_repo.py` with `api/package-index.json` and `public/debs/` updated):

1. Push the working branch to `origin`.
2. Open or update the pull request to `main` (mark **ready for review**, not draft).
3. **Merge to `main` yourself** — do not stop and wait for the user to click Merge in the Cursor UI:
   ```bash
   origin pr merge --branch "$(git rev-parse --abbrev-ref HEAD)" -s
   ```
   If merge is blocked on checks, fix them or use `origin pr merge --auto -s` after enabling merge-when-ready on that PR.
4. **Do not ask the user to click Deploy.** This repo is linked to Vercel on Origin; **merging `main` triggers production deploy** of `public/` (Sileo repo). Previews deploy from the PR branch automatically when Vercel is connected.

Only skip step 3 if the user explicitly said not to merge, or the change is experimental and should stay on a branch.

## Direct push to `main` (no PR)

When the user explicitly asks for **no pull request and no merge** (e.g. from a phone):

1. Work on `main` (or merge locally, then push `main` — still no PR).
2. Commit, then `git push origin main`.
3. Do **not** open a PR or run `origin pr merge`.
4. Vercel still deploys production from the `main` push.

## Release checklist (tweak versions)

- Bump `control` and `kDSBuildVersionString` in `shared/DSConstants.h`.
- Add a `changelog.md` entry.
- Build real dylibs: `make package FINALPACKAGE=1` (requires iOS toolchain; see `.cursor/environment.json` install).
- `python3 tools/make_repo.py` and commit the new deb + index.
- Merge to `main` per above.

## Never kill a staged app

Do not `killall` Beeper, and do not kill any staged app from SpringBoard or from `layout/DEBIAN/postinst`.

- 4.5.329 called `killForReason` while SpringBoard still had the scene. Safe mode.
- 4.5.336 added `killall Beeper` to postinst. Respring never finished, and re-jailbreaking boot-looped.

Do not set a scene presentation view's frame from SpringBoard. That call waits on the app and SpringBoard does not return, so respring hangs. Do not raise the stage window above the status bar. Do not write `TweakInject` from SpringBoard.

## Build environment

Linux Cloud Agents need the Theos iOS toolchain under `$THEOS/toolchain/linux/iphone/`. The environment `install` script downloads it if missing.
