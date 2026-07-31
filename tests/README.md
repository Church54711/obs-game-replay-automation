# Window identity runtime fixture

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

`runtime-config-default.txt` and `runtime-config-opt-in.txt` are isolated OBS
fixture inputs. The default case must log `using direct hook`; the opt-in case
must log `using helper (compatibility hook)`. Both ignore `javaw.exe` so a live
Minecraft client cannot become the fixture target.

`hook-policy-window-fixture.cs` is the short-lived target for those two cases.
It renders a basic OpenGL swap loop and keeps its window foreground briefly, so
OBS can prove the selected injection path without touching a real game.
