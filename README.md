# OBS Game Replay Automation

Windows automation for an installed copy of OBS Studio. The Lua script detects
the foreground fullscreen game, points Game Capture and Application Audio
Capture at that game, routes saved replays into per-game folders, and manages
the replay buffer. Merely detecting a fullscreen app does not create a folder.

Version 0.7.0 targets installed OBS Studio on Windows x64. Automated runtime
tests cover OBS Studio 32.2.2 and 33.0.1 in Simple and Advanced output modes.
The normal setup flow installs
into the detected OBS Studio folder under Program Files and requests
administrator permission.

## Quick install

For releases with a Windows installer, download
`obs-game-replay-automation-<version>-setup.exe` from the
[Releases page](https://github.com/Church54711/obs-game-replay-automation/releases).
Close OBS, run Setup, approve the administrator prompt, and confirm the detected
OBS folder. Fresh installations offer a replay-folder chooser; upgrades keep
the existing configuration exactly. Daily update notifications are optional.

Setup adds Start Menu shortcuts and an entry in Windows **Settings > Apps >
Installed apps**. On a first install, follow the last setup page to add the Lua
script in **OBS > Tools > Scripts**, then configure the capture sources below.
This project is an OBS Lua script, so OBS must load it through Tools > Scripts.
There is no native plugin DLL to discover automatically.

Uninstall with OBS closed. Uninstall removes the automation's runtime files and
its exact script registration from existing scene collections. It keeps replay
clips, the sidecar configuration, capture sources, profiles, unrelated scripts,
and recovery backups. Per-game settings and hotkeys stored in that script's OBS
registration are retained in the uninstall recovery copies of the scene files.
The initial setup builds are unsigned; Windows may show an unknown publisher.

The ZIP package is also available:

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

The EXE also accepts `/OBSROOT="D:\OBS Studio"`,
`/OBSCONFIGROOT="D:\OBS settings\obs-studio"`, `/REPLAYROOT="D:\Replays"`,
and `/SCRIPTSDIR="D:\Custom scripts"`. Use the OBS configuration folder chooser
for portable OBS (`<OBS folder>\config\obs-studio`) or another Windows account.
Close OBS yourself; Setup never force-closes it. Existing managed installations
must be uninstalled before changing their script or OBS configuration location.
For unattended setup, add `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` and run from
an elevated terminal. `/CURRENTUSER` supports writable portable OBS locations;
the default installation into Program Files requires administrator permission.

Fresh installs use `data\scripts\obs-game-replay-automation` inside the OBS
installation. Existing installations retain their original Lua path and config,
including the legacy `data\obs-plugins\frontend-tools\scripts` directory.
Lua scripts are loaded by their saved absolute path; they do not use OBS's
native plugin discovery. This avoids depending on the OBS 33 `core` layout or
the planned removal of legacy native plugin loading in OBS 34.

## OBS compatibility

The script checks the Lua APIs it needs before starting automation. If a future
OBS build removes an API, automation stays disabled with an explanatory log
message instead of partially changing capture sources or profile settings.
Newer version numbers alone do not disable the script.

The **OBS compatibility** GitHub Actions workflow downloads official Windows x64
builds, verifies their SHA-256 asset digests, and saves a real synthetic replay
in both output modes. It runs for pull requests, main-branch pushes, manually,
and weekly against OBS 32.2.2 and the latest stable OBS. Release publication
requires these checks to pass. Logs and sample replays are retained as workflow
artifacts; failed scheduled runs appear in Actions and follow your GitHub
notification preferences.

These checks cover API availability, capture source settings, x264 encoding,
lazy per-game/date routing, and routing cleanup. They do not certify every
game's graphics hook, anti-cheat, application audio, or hardware encoder.
Future OBS changes cannot be guaranteed compatible in advance; scheduled
tests detect regressions so they can be fixed. See [tests/README.md](tests/README.md)
for local reproduction.

## Required OBS sources

The active game scene needs these sources:

- Game Capture: a Game Capture source named Game Capture.
- Game Audio: an Application Audio Capture source named Game Audio.

The names can be changed in the config. The script warns and keeps retrying if
a source is missing, so adding the source later does not require restarting
OBS.

## Controls, status, and hotkeys

Open **Tools > Scripts > game-replay-auto.lua**. The status panel reports the
detected game, destination, buffer state, last confirmed clip, and warnings.
Click **Refresh status** for a current snapshot; action buttons also refresh it.
This panel is not a continuously updating dock.

- **Pause automation** stops a buffer owned by this script and clears its capture
  targets. A buffer you started yourself is left running.
- **Resume / clear session ignores** resumes automatic detection, clears manual
  stop suppression and session-only ignores, and retains permanent exclusions.
- **Ignore current game for this session** suppresses that game process until
  Resume or script reload. It does not change your permanent configuration.
- **Save replay now** requests one save and warns if OBS has not confirmed it
  within 30 seconds. OBS 33's save-start event also monitors native save requests.
- **Open last saved clip** opens the actual path returned by OBS in your default
  media player. It never guesses the filename.

Assign shortcuts under **Settings > Hotkeys**: Pause replay automation, Resume
replay automation, Ignore current game for this session, Save replay with
confirmation, and Open last saved replay. No key combinations are assigned by
default. Hotkeys persist with the scene collection's script settings.

Stopping the replay buffer manually suppresses automatic restart for the
tracked game. Resume explicitly clears that suppression. Automation only stops
or restarts buffers it started; manual buffers retain user ownership.

Enable **Play a sound after a confirmed replay save** for an optional Windows
notification sound. Save confirmation is always shown in status and the OBS log;
there are no desktop toast popups. **Warn below free space** defaults to 5 GiB;
0 disables the low-space threshold. Warnings never delete clips or change quality.

The optional **fallback replay folder** is disabled by default. When configured,
it is used only if the selected primary directory is unavailable and the fallback
already exists. Routing returns to the primary when it becomes available. Low
free space alone produces a warning, not an automatic destination change.

## Per-game editor

Focus a game, return to Tools > Scripts, then choose **Use current game**. Edit
the executable, optional title match, folder name, duration, fullscreen policy,
and **Allow this game**, then click **Apply game settings**. Alternatively, type
an executable name directly. Use a title match to distinguish games sharing
`javaw.exe`; current-game selection suggests the title for Java games.

Editor rules are saved with OBS's script settings. They override the matching
sidecar values for folder, duration, fullscreen, and enabled state, while retaining
sidecar-only options such as the hook policy. **Remove this editor rule** restores
sidecar/default behavior. Clearing **Allow this game** adds a permanent exclusion;
enabling it explicitly opts the match back in. **Apply** is required to commit
editor changes, and the sidecar file is never rewritten by the editor.

## Replay reliability

Automation waits for the configured source names/types and an existing output
directory. It rechecks sources while the game remains tracked, including while
you are in OBS, and recovers recreated sources. The OBS Replay Buffer option
must be enabled in Settings > Output; if its output is unavailable, status/logs
explain how to enable it without repeated start attempts.

Profile paths and replay duration are changed only temporarily for buffer startup
and restored after startup, failure, profile switch, or script unload. Any user
changes made during startup are preserved. Replay routing is applied to the replay
output rather than permanently changing the normal recording destination.

Malformed, unreadable, or partially written sidecar edits retain the last valid
configuration and show a warning. Valid edits are accepted after two stable reads.

## Change the replay folder

Open game-replay-auto-config.txt beside the Lua script and change this one line:

    root_folder=D:\OBS Replays

The default template uses:

    root_folder=%USERPROFILE%\Videos\OBS Replays

Environment variables and UNC paths are supported. Because OBS runs elevated
in this deployment, a mapped network drive must also be visible to elevated
processes. If it is not, use a UNC path such as \\server\share\OBS Replays.

The config is reread while OBS is running. The next detected game uses the new
root.

Once a game process is detected, its inferred game and folder name stay stable
until that process exits. Games that change their window title while running do
not create extra folders or make OBS repeatedly retarget the capture sources.

## Folder creation and ignored apps

The configured root folder must already exist. Detecting a game only selects
the final route and starts or retargets the replay buffer. The per-game folder,
including any date subfolders from your OBS filename format, is created by OBS
only when a replay is actually saved.

Executable names under `[ignored_exes]` never trigger the automation. Entries
saved in OBS under Tools > Scripts and entries in the sidecar config are merged.
Use the executable name shown in the OBS log; for example, 64-bit MPC-HC is
`mpc-hc64.exe`, not `mpc-hc.exe`. MPC-HC, Moonlight, Snipping Tool, and the
ChatGPT/Codex desktop process are ignored by default. To intentionally capture
an ignored executable, opt it back in explicitly:

    [game_overrides]
    moonlight.exe=enabled=true

## Updates

Version 0.4.0 and later install version metadata and a one-click updater beside
the Lua script. Open the Windows Start Menu, find OBS Game Replay Automation,
and choose Check for Updates. Launching it is the update confirmation: when a
newer stable release exists, it downloads the versioned package immediately,
verifies its SHA-256 checksum and GitHub asset digest when available, validates
the embedded VERSION and manifest, and then runs setup without another text
prompt.

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

Installation holds a per-directory lock, stages and hashes new files, backs up
existing runtime files/configuration/scene collections, verifies every copied
file, and commits VERSION/manifest last. On a file, config, or scene-migration
failure, it restores the previous files and removes newly installed files.
An incomplete rollback retains recovery data and reports its location.

Successful upgrades also retain a `.game-replay-install-<id>` recovery directory
beside the Lua script. Its `recovery.json` maps original paths to backed-up files
and hashes. No recovery directories are automatically deleted after successful
installs. Shortcut or scheduled-notification setup failures produce warnings
without undoing a verified installation. This is installation rollback, not
automatic rollback after a later OBS/game runtime problem.

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

To build the Windows setup EXE with Inno Setup 6.4+ or 7:

    .\build-installer.ps1 -CompilerPath "C:\Program Files\Inno Setup 7\ISCC.exe"

The builder validates/packages the payload, compiles the wizard, and writes an
EXE plus SHA-256 checksum under `dist`. A pinned, signature- and checksum-verified
portable compiler can be prepared with `tests/get-inno-setup.ps1 -Destination
"<fresh folder>"`. It makes no Start Menu or Installed Apps entries.

With OBS closed, test the actual setup and uninstaller in temporary folders:

    .\tests\windows-setup-tests.ps1 -SetupPath ".\dist\obs-game-replay-automation-0.7.0-setup.exe"

This uses a temporary per-user Installed Apps entry, refuses to replace an
existing per-user installation, and leaves the real OBS installation untouched.
It exercises running-OBS refusal, Unicode paths, upgrade preservation, late
failure, locked-file uninstall, and removal without deleting saved user data.

## Publish a GitHub release

The repository validates every push and pull request on a GitHub-hosted Windows
runner. To publish, update VERSION, manifest.json, and CHANGELOG.md together,
commit the change, and push the matching tag:

    git tag v0.7.0
    git push origin v0.7.0

The release workflow reruns package validation, rejects a mismatched tag,
builds/tests the setup EXE, publishes the versioned EXE and ZIP with checksums, creates stable latest-download aliases
for the website, and writes machine-readable latest.json metadata.

## License

OBS Game Replay Automation is licensed under the Zero-Clause BSD license
(`0BSD`). Anyone may use, copy, modify, redistribute, or sell the
software without an attribution requirement. The software is provided as-is,
without warranty. See LICENSE for the complete terms.

## Files

- game-replay-auto.lua: script loaded by OBS.
- game-replay-auto-config.txt: editable sidecar config.
- CHANGELOG.md: version history.
- LICENSE: Zero-Clause BSD terms included with source, installs, and releases.
- install.ps1: installed-OBS detector, elevated installer, and output chooser.
- Install OBS Game Replay Automation.cmd: double-click setup launcher.
- update.ps1: stable-release checker, verifier, downloader, and upgrade runner.
- Update OBS Game Replay Automation.cmd: one-click updater launcher.
- package.ps1: source-only release builder and validation (not included in the
  recipient zip).
- build-installer.ps1 and installer/: Windows setup compiler, wizard, and guarded
  installation/uninstall helper (not included in the ZIP).
- manifest.json and VERSION: release metadata.

## Troubleshooting

- If a game does not trigger, confirm it covers at least the configured
  fullscreen percentage or add a per-game fullscreen_only=false override.
- If OBS reports a missing source, confirm the source name and source type.
- If setup says OBS is running, exit OBS from its File menu or system tray and
  run setup again.
- If the replay root is unavailable, rerun setup and select an existing path
  visible to elevated applications.
- If a utility triggers unexpectedly, copy its exact executable name from the
  OBS log into `[ignored_exes]`.
- If a protected game is black in Game Capture, add only that executable under
  [game_overrides] with anti_cheat_hook=true.
- If an update is found while OBS is open, close OBS and launch Check for
  Updates again from the Start Menu.
- If GitHub cannot be reached, the installed version continues working; retry
  the update check after connectivity is restored.
- If an OpenGL game has a native NVIDIA driver crash, test with NVIDIA App's
  In-Game Overlay disabled so OBS is the only capture hook under test.
- Script messages appear in Help > Log Files > View Current Log.
