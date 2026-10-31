# Changelog

## 0.8.0 - Unreleased

- Unified install, update, and uninstall paths in an installation record. ZIP
  updates preserve custom OBS configuration paths and synchronize EXE maintenance
  files and the Windows Installed Apps version.
- Migrated preferences, per-game rules, and hotkeys to a versioned user settings
  file under the selected OBS configuration folder, with migration backups,
  validated import/export, atomic writes, and concurrent-writer protection.
- Split Lua development sources into ordered components while retaining one
  generated, installable script. Packaging rejects a stale generated bundle.
- Added first-run checks, explicit folder/source setup actions, a continuously
  refreshed local status page, and diagnostics that omit personal paths/names.
- Added scheduled/manual OBS prerelease early warnings and optional real OpenGL
  capture, application-audio tone, and NVENC acceptance tests with decoded media
  checks. Commercial game and anti-cheat behavior still requires game testing.
- Prepared optional timestamped publisher signing for Setup and its uninstaller,
  plus checksum/signature verification. Builds remain unsigned by default.

## 0.7.0 - 2026-10-30

- Added a standard Windows setup EXE with OBS and configuration folder selection,
  fresh-install replay folder selection, optional update notifications, Start
  Menu shortcuts, upgrade preservation, and a Windows Installed Apps entry.
- Added guarded uninstall with scene registration cleanup, recovery copies, and
  retained clips/configuration. Automated tests exercise the actual EXE and
  uninstaller; release workflows now build and publish the EXE and checksum.

- Respect manual replay-buffer stops and buffers started by the user. Added
  Pause, Resume, Ignore current game for this session, Save replay, and Open
  last saved clip controls with configurable OBS hotkeys.
- Temporarily apply replay startup settings, then restore the original profile
  values without overwriting intervening user edits. Handle profile switches,
  asynchronous start/stop events, and startup timeouts.
- Revalidate capture sources while tracking a game, recover recreated sources,
  wait for unavailable destinations, and support an explicitly configured
  fallback folder. Never create per-game folders until a replay is saved.
- Show status, destination, buffer state, warnings, and last confirmed replay
  in Tools > Scripts. Refresh status updates the panel; action buttons also
  refresh it. Optional save sound and configurable low-space warnings added.
- Added a per-game editor in Tools > Scripts, including current-game selection,
  executable/title matching, folder, duration, fullscreen policy, and exclusions.
  Overrides persist in OBS settings without writing to the protected sidecar.
- Retain the last valid sidecar configuration after malformed/partial edits.
- Transactional installation stages and verifies files, backs up runtime/config/
  scene files, validates copied files, and restores previous bytes on failure.
  Successful installs retain recovery files and commit version metadata last.
- Added lifecycle, editor, storage, save-feedback, installer fault-injection,
  and real-OBS serialization/source-recovery/manual-stop acceptance tests.

## 0.6.0 - 2026-10-30

- Added OBS 33.0.1 compatibility validation with real synthetic replay saves
  in Simple and Advanced output modes, retaining OBS 32.2.2 coverage.
- Fresh installs use an application-owned scripts directory independent of
  OBS's changing native plugin layout. Existing installs keep their original
  script path, updater target, and configuration.
- Check required Lua APIs, events, and Windows x64 LuaJIT support before
  starting automation; missing capabilities disable it with a clear diagnostic.
- Added reproducible isolated runtime tests, API-removal regression tests,
  and installer path tests. Runtime tests do not capture the user's desktop
  or audio and can run alongside normal OBS sessions.
- Added weekly latest-stable OBS compatibility CI, retained replay/log
  artifacts, and required compatibility tests before release publication.
- Validate packaging on both Windows PowerShell 5.1 and PowerShell 7.

## 0.5.0 - 2026-08-25

- Delayed per-game folder creation until a replay is actually saved. Detecting
  a fullscreen window now selects the destination without leaving an empty
  folder behind.
- Preserved the user's OBS replay filename and date-folder format by prefixing
  the active replay output's format with the selected game. OBS creates the
  complete destination itself during replay save, so its saved-path state stays
  accurate.
- Reset the profile's recording/replay base paths to the configured root rather
  than the last detected application's folder.
- Fixed `[ignored_exes]` in the sidecar config replacing exclusions saved in
  OBS's Scripts window. The two lists are now merged as documented.
- Added MPC-HC, Moonlight, Snipping Tool, and the ChatGPT/Codex desktop process
  to the default ignored executables. An explicit per-game `enabled=true`
  override can opt one back in.
- Added source regression checks for lazy folder creation, replay-format
  routing, exclusion merging, and ignored-app opt-in behavior.

## 0.4.1 - 2026-07-31

- Licensed the project under the OSI-approved Zero-Clause BSD license (`0BSD`),
  allowing unrestricted use, copying, modification, redistribution, and sale
  without an attribution requirement.
- Included LICENSE in source archives, installer deployments, updater archive
  validation, release metadata, automated tests, and the download website.

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
