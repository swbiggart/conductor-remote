# Fork notes (swbiggart/conductor-remote)

This fork runs the relay **from this source checkout** instead of the npm package, so the
daemon can never install code on its own (`resolveMode()` in `src/autoupdate.ts` refuses
`auto` when `.git` exists). Feature on top of upstream, on `feat/update-indicator`:

- `fix:` source checkouts resolve their version from the nearest git tag instead of the
  `0.0.0-development` placeholder, so "update available" is truthful.
- `feat:` `check` mode shows a passive "vX.Y.Z available" indicator in the PWA's
  ConnectSheet footer, plus `POST /api/update/check` to poll on demand.

## Branches

- `main` — clean mirror of `upstream/main` (hyldmo/conductor-remote). Never commit here.
  Sync: `git fetch upstream && git push origin upstream/main:main`
- `feat/update-indicator` — the two feature commits (+ this file). The service deploys
  from this branch, checked out in `~/Code/conductor-remote`.

## When the PWA footer says a new version is available

1. Open a Conductor workspace on this repo; have Claude fetch and review the delta:
   `git fetch upstream --tags && git diff v<current-base>..v<new>` (registry versions == git tags).
   This review is the reason the node binary keeps Accessibility.
2. If accepted: rebase this branch onto the new tag, `yarn verify`, push.
3. In `~/Code/conductor-remote`: `git pull`, then `AUTO_UPDATE=check yarn deploy`.
   The indicator clears itself — `git describe` now reports the new tag.

## Ops

From this directory: `yarn service status|restart|uninstall`, `node bin/cli.js logs`.
The LaunchAgent plist bakes the absolute node path — after replacing the nvm node
version, re-run `AUTO_UPDATE=check yarn deploy`.

Upstream PR plan: cherry-pick the two feature commits (without this file) onto a branch
cut from `main`.
