# OBS Game Replay Automation

Windows automation for an installed copy of OBS Studio. The Lua script detects
the foreground fullscreen game, points Game Capture and Application Audio
Capture at that game, routes saved replays into per-game folders, and manages
the replay buffer. Merely detecting a fullscreen app does not create a folder.

Version 0.8.0 targets installed OBS Studio on Windows x64. Automated runtime
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
script in **OBS > Tools > Scripts**, then use the first-run checks described below.
This project is an OBS Lua script, so OBS must load it through Tools > Scripts.
There is no native plugin DLL to discover automatically.

Uninstall with OBS closed. Uninstall removes the automation's runtime files and
its exact script registration from existing scene collections. It keeps replay
clips, the sidecar configuration, capture sources, profiles, unrelated scripts,
and recovery backups. Version 0.8 settings and hotkeys remain in the user
settings folder. Old scene-based settings also remain in uninstall recovery copies.
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
notification preferences. A separate scheduled/manual OBS prerelease workflow
tests newer beta/RC builds when available and reports failures without blocking
stable releases.

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

The names can be changed in Tools > Scripts. The script warns and keeps retrying if
a source is missing, so adding the source later does not require restarting
OBS.

## Controls, status, and hotkeys

Open **Tools > Scripts > game-replay-auto.lua**. The status panel reports the
detected game, destination, buffer state, last confirmed clip, and warnings.
Click **Refresh status** for a current snapshot; action buttons also refresh it.
**Open live status** opens a local page that refreshes every second while OBS
runs. It includes the same status and setup checks without a network server.
The Scripts property panel remains a snapshot; the HTML page is the live view.
It contains your paths and game names, so use the diagnostic report for sharing.

**Check setup and folder writing** checks capture source types, membership in the
current scene, destination writing, replay-buffer configuration, replay length,
and whether the Save replay hotkey is assigned. **Add missing capture sources**
creates or reuses only the selected sources in the current scene and refuses
conflicting names or changes during recording/streaming. **Create the selected
replay folder** is an explicit action; detection never creates empty game folders.
Enable Replay Buffer in OBS Settings > Output and assign hotkeys yourself.

**Export diagnostic report** writes diagnostics.json beside the user settings.
It includes script/OBS versions and health flags, with no personal paths, game
names, source names, scene data, or raw OBS logs.

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
default. Hotkeys persist in the shared user settings file across scene collections.

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

Editor rules are saved in the shared user settings file. They override matching
advanced per-game rules for folder, duration, fullscreen, and enabled state,
while retaining options such as the hook policy. **Remove this editor rule**
restores advanced/default behavior. Clearing **Allow this game** adds a permanent
exclusion; enabling it opts the match back in. **Apply** commits editor changes.

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

## Settings, migration, and recovery

Version 0.8 stores preferences, game rules, and hotkeys in one versioned file:

    %APPDATA%\obs-studio\game-replay-automation\settings.json

Portable/custom installs use <selected OBS configuration folder>\game-replay-automation.
The exact location is shown in Tools > Scripts. Installation paths are recorded
separately beside the Lua script in game-replay-installation.json; the installer,
updater, and uninstaller use that same record.

On the first load, the script imports legacy OBS script settings and the sidecar
configuration, preserving their previous precedence and combined exclusions.
It writes migration backups before saving. The original sidecar is retained
unchanged, then stops being an active configuration source. Subsequent scene
collections use the shared preferences instead of replacing them with defaults.
The first scene collection loaded supplies any legacy scene-specific settings;
other old scene copies remain intact for recovery.

Change the replay folder and other settings in **OBS > Tools > Scripts**.
The replay-length override accepts 0 to use the current OBS profile's duration.
For transfer or backup, select a JSON file and use **Export settings** or
**Import settings**. Exports contain your paths, rules, and hotkeys.
An import validates the document and backs up the current file before replacing
it under a write lock. Invalid/future schemas are rejected. A corrupt file or
conflicting OBS writer pauses automation and preserves the existing file;
reload the script or explicitly import a valid backup to recover.

Environment variables and UNC paths work in replay paths. Mapped drives must be
visible to the account/elevation level running OBS. The root must exist, or use
the explicit Create folder action. The next detected game uses the new root.
Game identity stays stable until its process exits, even if its window title changes.

## Folder creation and ignored apps

The configured root folder must already exist. Detecting a game only selects
the final route and starts or retargets the replay buffer. The per-game folder,
including any date subfolders from your OBS filename format, is created by OBS
only when a replay is actually saved.

Executable names in Ignored executable names never trigger automation. During
migration, entries saved under Tools > Scripts and entries in the sidecar config are merged.
Use the executable name shown in the OBS log; for example, 64-bit MPC-HC is
`mpc-hc64.exe`, not `mpc-hc.exe`. MPC-HC, Moonlight, Snipping Tool, and the
ChatGPT/Codex desktop process are ignored by default. To intentionally capture
an ignored executable, opt it back in explicitly:

    moonlight.exe=enabled=true

Enter that rule in Advanced per-game overrides in Tools > Scripts.

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

Run the new installer or the installed updater with OBS closed. Runtime files
and release metadata are replaced while legacy configuration and canonical user
preferences are preserved. The updater uses the recorded script, OBS config,
and settings directories, including portable/custom configurations.
Older EXE installs recover those locations from their Installed Apps inventory.
An older ZIP-only install with a custom OBS configuration folder needs one manual
0.8 upgrade with -ObsConfigRoot supplied, because it has no saved location record.

EXE-managed installs also update their maintenance payload and Installed Apps
version when the ZIP updater runs, so uninstall uses the current inventory.
Daily notification preferences are preserved on unattended updates.

Setup backs up scene collections before clearing stale Game Capture targets
and applying the safe direct-hook default. After migration it reads the selected
source name from canonical preferences. Invalid preferences are retained for
repair in OBS. -OverwriteConfig applies only before migration; after migration
use OBS settings or an explicit JSON import.

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

## Advanced rules

Use Game folder overrides for executable/title-to-folder mappings, and Advanced
per-game overrides for behavior:

    game.exe|optional title=My Game
    game.exe=replay_seconds=120;fullscreen_only=false;enabled=true

These belong in their respective fields, without section headers. The original
game-replay-auto-config.txt documents the legacy template format used only during
first-load migration. The per-game editor is the simpler way to change common options.

## Game Capture hook safety

This automation explicitly disables OBS's anti-cheat compatibility hook by
default. That gives ordinary games, including Minecraft Java Edition, the
normal direct Game Capture hook instead of the compatibility helper.

Only opt a game in when its anti-cheat blocks normal Game Capture:

    protectedgame.exe=anti_cheat_hook=true

The script manages this Game Capture setting whenever it selects a game. Do not
use the source's OBS checkbox as a global setting; put the exception in the
Advanced per-game overrides field so it follows the correct game.

While OBS is idle with no game actively tracked, the normal poll also aligns a
saved target's direct/helper policy with the matching per-game override.

An injection method cannot be swapped reliably after OBS has already injected
its graphics-hook DLL into a running game. Close OBS before setup, and restart a
game after changing its anti_cheat_hook override so the next process launch
starts with the intended method. Start OBS before that restarted game, or rerun
setup while OBS is closed to clear a stale saved target first.

## Build a release

Source components live in src/ and are concatenated in src/bundle.json order.
They share one Lua scope; recipients still install one script with no module
search paths or runtime loader. Edit a component, then regenerate the bundle:

    .\build-lua.ps1
    .\package.ps1

Packaging rejects a stale bundle. Commit both components and generated Lua.

This validates the source metadata and PowerShell syntax, then builds:

    ..\dist\obs-game-replay-automation-<version>.zip

The build also writes a matching .sha256.txt checksum file for transfer
verification.

The release zip contains only the files needed by recipients. It does not
contain portable OBS, tests, personal paths, or prior release folders.

To build the Windows setup EXE with Inno Setup 6.4+ or 7:

    .\build-installer.ps1 -CompilerPath "C:\Program Files\Inno Setup 7\ISCC.exe"

Signing is optional and disabled by default. See [signing/README.md](signing/README.md)
for publisher-certificate setup and verification. Unsigned builds retain the
unknown-publisher prompt. No trusted signed release is claimed.

The builder validates/packages the payload, compiles the wizard, and writes an
EXE plus SHA-256 checksum under `dist`. A pinned, signature- and checksum-verified
portable compiler can be prepared with `tests/get-inno-setup.ps1 -Destination
"<fresh folder>"`. It makes no Start Menu or Installed Apps entries.

With OBS closed, test the actual setup and uninstaller in temporary folders:

    .\tests\windows-setup-tests.ps1 -SetupPath ".\dist\obs-game-replay-automation-0.8.0-setup.exe"

This uses a temporary per-user Installed Apps entry, refuses to replace an
existing per-user installation, and leaves the real OBS installation untouched.
It exercises running-OBS refusal, Unicode paths, upgrade preservation, late
failure, locked-file uninstall, and removal without deleting saved user data.

## Publish a GitHub release

The repository validates every push and pull request on a GitHub-hosted Windows
runner. To publish, update VERSION, manifest.json, and CHANGELOG.md together,
commit the change, and push the matching tag:

    git tag v0.8.0
    git push origin v0.8.0

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
- game-replay-auto-config.txt: legacy first-load migration template.
- CHANGELOG.md: version history.
- LICENSE: Zero-Clause BSD terms included with source, installs, and releases.
- install.ps1: installed-OBS detector, elevated installer, and output chooser.
- Install OBS Game Replay Automation.cmd: double-click setup launcher.
- update.ps1: stable-release checker, verifier, downloader, and upgrade runner.
- Update OBS Game Replay Automation.cmd: one-click updater launcher.
- package.ps1: source-only release builder and validation (not included in the
  recipient zip).
- build-installer.ps1 and installer/: source for the Windows setup EXE.
- setup-bridge.ps1: bundled maintenance helper for EXE-managed updates.
- installation.ps1: shared installation record and updater path helpers.
- verify-release.ps1: checksum and optional Authenticode verification.
- src/ and build-lua.ps1: source-only Lua components and bundle generator.
- manifest.json and VERSION: release metadata.

## Troubleshooting

- If a game does not trigger, confirm it covers at least the configured
  fullscreen percentage or add a per-game fullscreen_only=false override.
- If OBS reports a missing source, confirm the source name and source type.
- If setup says OBS is running, exit OBS from its File menu or system tray and
  run setup again.
- If the replay root is unavailable, choose an existing path in Tools > Scripts.
- If a utility triggers unexpectedly, copy its exact executable name from the
  OBS log into Ignored executable names in Tools > Scripts.
- If a protected game is black in Game Capture, add only that executable under
  Advanced per-game overrides with anti_cheat_hook=true.
- If an update is found while OBS is open, close OBS and launch Check for
  Updates again from the Start Menu.
- If GitHub cannot be reached, the installed version continues working; retry
  the update check after connectivity is restored.
- If an OpenGL game has a native NVIDIA driver crash, test with NVIDIA App's
  In-Game Overlay disabled so OBS is the only capture hook under test.
- Script messages appear in Help > Log Files > View Current Log.
