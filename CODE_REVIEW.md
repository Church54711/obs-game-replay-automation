# Code Review - 0.3.2

Date: 2026-07-30

## Result

Version 0.3.2 is ready to distribute for the reviewed Windows x64 / installed
OBS workflow. The final package defaults automated Game Capture targets to
OBS's direct hook, retains an explicit per-game compatibility-helper override,
and migrates the configured source safely while OBS is closed.

The live installed OBS files and scene collection were not modified during
this investigation. Runtime acceptance used a disposable OBS 32.1.2 clone and
a purpose-built OpenGL fixture. The installed OBS log under investigation is
from OBS 32.2.1.

## Crash diagnosis

- At 18:35:53 CDT, the JVM terminated with `EXCEPTION_ACCESS_VIOLATION` in
  NVIDIA `nvapi64_impl.dll` on Minecraft's Render thread during
  `GLFW.glfwSwapBuffers`.
- OBS selected `javaw.exe` at 18:35:36, logged `using helper (compatibility
  hook)`, and completed OpenGL shared-texture capture at 18:35:38. The native
  crash followed about 15.5 seconds later.
- The saved Game Capture source had `anti_cheat_hook=true`. The automation did
  not previously write that field, so it inherited OBS's default/source state.
- Windows Error Reporting shows both OBS `graphics-hook64.dll` and NVIDIA
  `nvspcap64.dll` in the JVM. The user has confirmed that no NVIDIA or other
  overlay was enabled or used. DLL presence alone does not establish an active
  overlay or causal involvement, so this is not treated as an overlay conflict.
- The strongest supported trigger remains the unnecessary OBS compatibility-
  helper injection into `javaw.exe` shortly before the NVIDIA native fault.
  The timing is strong evidence of an interaction, but it does not prove that
  the helper alone caused the NVIDIA driver to fail.
- The JVM report does not support Java heap exhaustion. The archived client
  log ends without a Java exception or server rejection, all 32 logical CPUs
  were active, and the later OpenAL fast-fail report is consistent with
  secondary shutdown after the NVIDIA fatal error.

## Changes made

- `anti_cheat_hook=false` is now the automation default.
- Every Game Capture retarget explicitly writes the selected hook policy.
- A per-game override preserves compatibility-helper behavior where required:

      [game_overrides]
      protectedgame.exe=anti_cheat_hook=true

- Policy changes on the same target save the new value, clear the target, wait
  for OBS's in-flight attempt, and then retry. A success message is emitted
  only after both configured capture sources accept their updates.
- While no game is actively tracked, polling aligns a saved target's policy
  with its matching per-game override.
- Setup now refuses to proceed while any OBS process is running.
- While OBS is closed, setup backs up each affected scene collection, sets the
  configured Game Capture source to `anti_cheat_hook=false`, and clears its
  stale saved target. Clearing the target prevents OBS from racing the Lua
  automation with an old policy when the next game process is already running.
- Installer migration follows the configured `game_capture_source` name,
  validates the rewritten JSON, and restores the backup automatically if
  validation fails.
- Documentation, release metadata, changelog, static policy tests, and the
  source-only OpenGL runtime fixture were updated.

## Verification

- PowerShell parsing passed for `install.ps1`, `package.ps1`, and the hook
  policy test script.
- Static hook-policy and installer-migration checks passed as part of the final
  package build.
- The packaged installer converted a valid scene from
  `anti_cheat_hook=true` with a saved target to `false` with an empty target.
  Its exact pre-change scene backup remained valid JSON.
- An isolated migration of the real 708,050-byte live scene collection copy
  preserved a byte-identical backup, kept all eight sources, and produced a
  normalized semantic document differing only in the intended hook and
  saved-target fields.
- Final-package default case:
  - installer-cleared scene;
  - fixture already running before OBS;
  - one `using direct hook`;
  - successful OpenGL shared-texture capture;
  - no compatibility-helper selection;
  - no `javaw.exe` hook attempt;
  - saved scene retained `anti_cheat_hook=false`;
  - clean OBS shutdown.
- Final-package override case:
  - installer-cleared scene;
  - `anti_cheat_hook=true` for the fixture executable;
  - one `using helper (compatibility hook)`;
  - successful OpenGL shared-texture capture;
  - no direct-hook selection;
  - no `javaw.exe` hook attempt;
  - saved scene retained `anti_cheat_hook=true`;
  - clean OBS shutdown.
- The final zip contains the expected flat eight-file recipient layout.
  Source and staging hashes match for all eight files.
- Final release SHA-256:
  `ea0d5fee456bb852b9af62311c9247b3fa73a59ef354e9620a2f86d68d252827`.

Runtime evidence is under
`dist/verification/0.3.2-hook-policy/`.

## Rollback

The prior immutable release remains available as
`dist/obs-game-replay-automation-0.3.1.zip`.

SHA-256:
`f4f7e2f58fb2940ab257662fc03e9b659eb9b58de4c6492390127366b4f1c74a`.

On each recipient machine, the 0.3.2 installer also creates backups beside any
config or scene file it changes.

## Remaining NVIDIA caveat

The user confirms that no NVIDIA or other overlay was enabled or used. Although
`nvspcap64.dll` appeared in Windows Error Reporting, module presence alone does
not show that an overlay was active, so this diagnosis does not attribute the
crash to an overlay.

NVIDIA driver 610.88 was installed when the crash occurred. The fatal
instruction was inside NVIDIA `nvapi64_impl.dll`; the most relevant external
event remains OBS's unnecessary compatibility-helper injection shortly
beforehand.

Version 0.3.2 removes that helper path for Minecraft, but direct Game Capture
still uses OBS's normal graphics hook. If the crash recurs with 0.3.2, retain
the direct-hook policy and collect fresh JVM, OBS, and WER evidence. A
recurrence with no overlay and no compatibility helper would point more
strongly to an NVIDIA/OpenGL/normal OBS Game Capture interaction, not a reason
to re-enable the compatibility helper.

## Deployment boundary

An injection method cannot be replaced reliably after the graphics-hook DLL is
already loaded into a running game. Close OBS before setup. After changing a
per-game `anti_cheat_hook` override, restart that game and start OBS before the
restarted game, or rerun setup while OBS is closed to clear the saved target.
