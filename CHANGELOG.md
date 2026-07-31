# Changelog

## 0.4.0 - 2026-07-31

- Added a GitHub Releases updater that compares semantic versions, downloads
  the exact stable package, verifies its SHA-256 and GitHub asset digest when
  available, and validates the package's embedded version metadata.
- Made the updater refuse installation while OBS is running and reuse the
  existing safe installer instead of replacing loaded files.
- Installed VERSION, manifest.json, the updater, and a Start Menu update
  shortcut beside the Lua script.
- Added optional daily, limited-privilege update notifications. The scheduled
  check can notify but installation into Program Files still requires the
  normal Windows administrator approval.
- Preserved the complete existing user config during updates, including replay
  root, source names, mappings, and per-game overrides. The updater targets its
  exact installed scripts directory so custom locations remain stable.
- Made updater launch the update immediately after finding a newer release. If
  OBS is open, the same updater waits with Retry/Cancel while the user closes
  OBS instead of requiring another launch.
- Added an installer-side config hash invariant that restores the exact prior
  bytes and stops if a non-interactive update unexpectedly changes settings.
- Added an isolated byte-for-byte config-preservation regression test.
- Added tag-driven GitHub release automation with versioned assets, stable
  latest-download aliases, checksums, and latest.json metadata.
- Added continuous package validation on pushes and pull requests.
- Added a responsive, tracking-free GitHub Pages download and documentation
  site.

## 0.3.2 - 2026-07-30

- Disabled OBS's anti-cheat compatibility hook by default for automated Game
  Capture targets, including Minecraft Java Edition.
- Added a per-game anti_cheat_hook=true override for games whose anti-cheat
  genuinely requires the compatibility helper.
- Explicitly writes the hook policy on every capture target update instead of
  inheriting the shared Game Capture source's previous/default value.
- Forces a clean unhook, waits for OBS's in-flight hook attempt to finish, and
  then re-hooks when only the compatibility policy changes, because OBS does
  not reset an active capture for that setting alone.
- Defers the success log until both configured capture sources accepted the
  requested update.
- Requires OBS to be closed during setup, then backs up and migrates the
  configured Game Capture source to anti_cheat_hook=false in each installed-OBS
  scene collection before the next game launch. Setup also clears that source's
  stale saved target so it cannot race the automation on first launch.
- Aligns an idle saved target's direct/helper policy with the matching per-game
  override during normal polling.
- Added source/package checks that prevent the safe default and override wiring
  from silently regressing.

## 0.3.1 - 2026-07-19

- Kept inferred game and folder names stable for the lifetime of the detected
  process.
- Stopped changing-window titles from repeatedly retargeting OBS sources.
- Changed capture identity to use the actual HWND, process id, and executable.
- Preserved source retries when a required source is missing or mistyped.
- Kept live config remapping deterministic by matching against the process's
  original detected title.

## 0.3.0 - 2026-07-19

- Reworked setup for installed OBS Studio on Windows x64.
- Added automatic administrator elevation and installed-OBS detection.
- Added a replay output folder prompt with write validation.
- Made root_folder the single obvious output-location setting.
- Replaced the personal V: default with a portable per-user Videos default.
- Added environment-variable and UNC output-path support.
- Preserved existing config during upgrades and added automatic config backups.
- Fixed the game-exit delay so it starts when process exit is first confirmed.
- Fixed missing or mistyped OBS sources so the script retries after correction.
- Fixed per-game enabled=false and fullscreen_only=false overrides.
- Reset the stable-game candidate after interrupted detections.
- Added safer Windows folder-name and directory handling.
- Removed unused replay-buffer profile keys.
- Added release validation and a flat, recipient-ready zip layout.
- Added a SHA-256 checksum file beside each release zip.

## 0.2.2

- Previous local development release.
