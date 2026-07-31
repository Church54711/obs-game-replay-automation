# OBS Game Replay Automation

Windows automation for an installed copy of OBS Studio. The Lua script detects
the foreground fullscreen game, points Game Capture and Application Audio
Capture at that game, creates a per-game folder, updates the recording/replay
path, and manages the replay buffer.

Version 0.4.0 targets installed OBS Studio on Windows x64. The replay automation
itself was runtime-tested with OBS Studio 32.1.2. The normal setup flow installs
into the detected OBS Studio folder under Program Files and requests
administrator permission.

## Quick install

1. Close OBS Studio completely.
2. Extract the release zip.
3. Double-click:

       Install OBS Game Replay Automation.cmd

4. Approve the Windows administrator prompt.
5. Enter or paste the folder where replay clips should be saved. Press Enter to
   accept the default Videos\OBS Replays folder.
6. Choose whether setup should enable a limited-privilege daily update
   notification. It is enabled by default when you press Enter.
7. In OBS, open Tools > Scripts, click +, and select the exact Lua path printed
   by setup.

The installer verifies that the selected replay folder is writable from the
same elevated context OBS will use. It stops with a clear message if OBS is
running, because scene collections must be migrated while OBS is closed.

To run setup directly from PowerShell:

    .\install.ps1

For an unattended install from an already elevated PowerShell:

    .\install.ps1 -OutputRoot "D:\OBS Replays" -EnableUpdateChecks -NonInteractive

Use -ObsRoot for a nonstandard installed OBS location, or -ScriptsDir to supply
the final OBS scripts directory directly.

## Required OBS sources

The active game scene needs these sources:

- Game Capture: a Game Capture source named Game Capture.
- Game Audio: an Application Audio Capture source named Game Audio.

The names can be changed in the config. The script warns and keeps retrying if
a source is missing, so adding the source later does not require restarting
OBS.

## Change the replay folder

Open game-replay-auto-config.txt beside the Lua script and change this one line:

    root_folder=D:\OBS Replays

The default template uses:

    root_folder=%USERPROFILE%\Videos\OBS Replays

Environment variables and UNC paths are supported. Because OBS runs elevated
in this deployment, a mapped network drive must also be visible to elevated
processes. If it is not, use a UNC path such as \\server\share\OBS Replays.

The config is reread while OBS is running. The next detected game/folder update
uses the new root.

Once a game process is detected, its inferred game and folder name stay stable
until that process exits. Games that change their window title while running do
not create extra folders or make OBS repeatedly retarget the capture sources.

## Updates

Version 0.4.0 installs version metadata and a one-click updater beside the Lua
script. Open the Windows Start Menu, find OBS Game Replay Automation, and choose
Check for Updates. Launching it is the update confirmation: when a newer stable
release exists, it downloads the versioned package immediately, verifies its
SHA-256 checksum and GitHub asset digest when available, validates the embedded
VERSION and manifest, and then runs setup without another text prompt.

If daily update notifications were enabled during setup, Windows runs a
limited-privilege check at 12:00 PM and runs it later when that time was missed.
The scheduled check can only notify. Installing into Program Files still uses
the normal Windows administrator prompt.

The updater never closes OBS. If OBS is running, the same updater displays a
Retry/Cancel prompt; close OBS and select Retry to continue without relaunching
the updater. Existing installations older than 0.4.0 need one manual upgrade
before the updater and notification task are available.

To disable or re-enable daily checks, rerun setup while OBS is closed:

    .\install.ps1 -DisableUpdateChecks
    .\install.ps1 -EnableUpdateChecks

## Upgrade behavior

Run the new installer or the installed updater. It always updates the Lua
script, updater, and release metadata, but preserves the complete existing
config, including source names, game-folder mappings, per-game overrides, and
the selected replay root. The config template is copied only for a first
install or when -OverwriteConfig is explicitly supplied. If root_folder is
intentionally changed during interactive setup, the previous config is saved
beside it as a .bak file.

The updater passes its exact installed scripts directory back to setup. This
keeps custom OBS installation locations on the same copy instead of relying on
standard-path rediscovery. Non-interactive updates preserve the existing daily
notification preference. Setup also hashes the config before and after an
updater-driven installation. If an unexpected change is detected, it restores
the exact pre-update bytes and stops with an error.

While OBS is closed, setup also sets the configured Game Capture source to the
safe direct-hook default and clears its stale saved target in each scene
collection. That prevents OBS from racing the automation with an old hook
policy on the first launch. Every scene file it changes is backed up beside the
original first. Re-running setup does not create another scene backup when the
source is already safe and untargeted.

Use -OverwriteConfig only when you intentionally want to reset all settings to
the release defaults. A backup is still created first.

## Main settings

    root_folder=%USERPROFILE%\Videos\OBS Replays
    game_capture_source=Game Capture
    game_audio_source=Game Audio
    fullscreen_only=true
    fullscreen_min_coverage_percent=98
    match_priority=2
    default_replay_seconds=120
    stop_replay_buffer_when_game_exits=true
    game_exit_stop_delay_seconds=15

Game-specific folder names belong under [game_folders]. Game-specific behavior
belongs under [game_overrides]. The examples in the config explain both
formats.

## Game Capture hook safety

This automation explicitly disables OBS's anti-cheat compatibility hook by
default. That gives ordinary games, including Minecraft Java Edition, the
normal direct Game Capture hook instead of the compatibility helper.

Only opt a game in when its anti-cheat blocks normal Game Capture:

    [game_overrides]
    protectedgame.exe=anti_cheat_hook=true

The script manages this Game Capture setting whenever it selects a game. Do not
use the source's OBS checkbox as a global setting; put the exception in the
sidecar config so it follows the correct game.

While OBS is idle with no game actively tracked, the normal poll also aligns a
saved target's direct/helper policy with the matching per-game override.

An injection method cannot be swapped reliably after OBS has already injected
its graphics-hook DLL into a running game. Close OBS before setup, and restart a
game after changing its anti_cheat_hook override so the next process launch
starts with the intended method. Start OBS before that restarted game, or rerun
setup while OBS is closed to clear a stale saved target first.

## Build a release

From the source folder:

    .\package.ps1

This validates the source metadata and PowerShell syntax, then builds:

    ..\dist\obs-game-replay-automation-<version>.zip

The build also writes a matching .sha256.txt checksum file for transfer
verification.

The release zip contains only the files needed by recipients. It does not
contain portable OBS, tests, personal paths, or prior release folders.

## Publish a GitHub release

The repository validates every push and pull request on a GitHub-hosted Windows
runner. To publish, update VERSION, manifest.json, and CHANGELOG.md together,
commit the change, and push the matching tag:

    git tag v0.4.0
    git push origin v0.4.0

The release workflow reruns package validation, rejects a mismatched tag,
publishes the versioned ZIP and checksum, creates stable latest-download aliases
for the website, and writes machine-readable latest.json metadata.

## Files

- game-replay-auto.lua: script loaded by OBS.
- game-replay-auto-config.txt: editable sidecar config.
- CHANGELOG.md: version history.
- install.ps1: installed-OBS detector, elevated installer, and output chooser.
- Install OBS Game Replay Automation.cmd: double-click setup launcher.
- update.ps1: stable-release checker, verifier, downloader, and upgrade runner.
- Update OBS Game Replay Automation.cmd: one-click updater launcher.
- package.ps1: source-only release builder and validation (not included in the
  recipient zip).
- manifest.json and VERSION: release metadata.

## Troubleshooting

- If a game does not trigger, confirm it covers at least the configured
  fullscreen percentage or add a per-game fullscreen_only=false override.
- If OBS reports a missing source, confirm the source name and source type.
- If setup says OBS is running, exit OBS from its File menu or system tray and
  run setup again.
- If the output folder cannot be created, rerun setup and select a path visible
  to elevated applications.
- If a protected game is black in Game Capture, add only that executable under
  [game_overrides] with anti_cheat_hook=true.
- If an update is found while OBS is open, close OBS and launch Check for
  Updates again from the Start Menu.
- If GitHub cannot be reached, the installed version continues working; retry
  the update check after connectivity is restored.
- If an OpenGL game has a native NVIDIA driver crash, test with NVIDIA App's
  In-Game Overlay disabled so OBS is the only capture hook under test.
- Script messages appear in Help > Log Files > View Current Log.
