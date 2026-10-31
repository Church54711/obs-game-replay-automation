# OBS compatibility tests

Download an official portable Windows x64 OBS build (asset digest verified),
then run these commands from the repository root:

```powershell
./tests/get-obs-release.ps1 -Version latest -Destination .tools/obs-latest
./tests/run-lua-tests.ps1 -LuaLibrary .tools/obs-latest/runtime/bin/64bit/lua51.dll
./tests/install-path-tests.ps1
./tests/obs-compatibility-test.ps1 -ObsRoot .tools/obs-latest/runtime -Mode Simple
./tests/obs-compatibility-test.ps1 -ObsRoot .tools/obs-latest/runtime -Mode Advanced
```

Use a fresh download directory each time. `-Version 32.2.2` selects the older
baseline. `-EvidenceDir` selects where logs, replay MKVs and JSON summaries go.
The runtime harness creates a fresh portable configuration, links only the OBS
distribution directories, and stops only its own child process. Normal OBS
sessions may remain open. It supports both the older `obs-plugins` layout and
the OBS 33 `core` layout; it never copies your normal OBS profile.

The appended test-only Lua driver substitutes foreground discovery, creates
hidden Game Capture / Application Audio Capture sources, and encodes a visible
color source using x264. It checks real source retargeting, no game folder before
save, a non-empty MKV under the game/date directory, and restoration of the
filename format. It does not test actual game injection or captured audio.
`ffprobe` or `ffmpeg -v error -i <replay> -f null -` can independently validate
the retained media. Runtime tests require a Windows desktop/D3D environment.

The Lua guard tests remove each required API/event independently and check that
startup disables automation without mutating OBS. Installer path tests load only
the pure path helpers into temporary fixtures and do not run installation.

GitHub Actions runs the runtime tests against 32.2.2 and latest stable weekly,
on PRs/pushes, and before publishing releases. This workflow must be merged into
the default branch for scheduled checks to run. GitHub may disable schedules
in inactive repositories; check the Actions tab when resuming maintenance.

## Older foreground window fixtures

This source-only fixture is not included in recipient release zips. It provides
a repeatable foreground-window sequence for manually validating capture identity
changes in an isolated OBS profile:

1. `Stable Identity Alpha` on the initial HWND.
2. `Transient Title Beta` on the same HWND.
3. `Replacement Window Gamma` on a new HWND in the same process.
4. `Transient Title Delta` on the replacement HWND.

The expected script behavior is two configuration events, one output folder
named `Stable Identity Alpha`, and no configuration event for Beta or Delta.
Close or defocus other fullscreen applications before running the fixture.

Compile on Windows with the .NET Framework C# compiler:

    C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /optimize+ /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /out:window-identity-fixture.exe window-identity-fixture.cs

`hook-policy-tests.ps1` is run automatically by `package.ps1`. It checks that
the Lua source retains the safe compatibility-hook default, explicit OBS
setting, same-target reset, per-game override, installer scene migration, and
matching recipient documentation. Runtime acceptance still requires isolated
OBS because this source check cannot prove which injector OBS selected.

`replay-routing-tests.ps1` is also run by `package.ps1`. It prevents detection-
time directory creation from returning, checks that the active replay filename
format is prefixed with the selected game, and verifies that sidecar and OBS UI
exclusions are merged. Runtime acceptance still requires a real replay save.

`runtime-replay-routing-test.ps1` performs that real-save acceptance check in a
temporary OBS profile. It launches the installed OBS binary against isolated
config, confirms the game folder is absent after detection, saves one five-
second replay, verifies the routed file and root-only profile paths, and retains
the OBS log plus a hash summary under `dist\verification`.

`runtime-config-default.txt` and `runtime-config-opt-in.txt` are isolated OBS
fixture inputs. The default case must log `using direct hook`; the opt-in case
must log `using helper (compatibility hook)`. Both ignore `javaw.exe` so a live
Minecraft client cannot become the fixture target.

`hook-policy-window-fixture.cs` is the short-lived target for those two cases.
It renders a basic OpenGL swap loop and keeps its window foreground briefly, so
OBS can prove the selected injection path without touching a real game.
