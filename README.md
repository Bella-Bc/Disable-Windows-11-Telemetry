# Disable-Windows-11-Telemetry

A reversible PowerShell script that reduces Windows 11 telemetry, tracking and feedback prompts. It records the original values before changing anything, so `-Restore` puts them back.

> **Note:** Windows Home and Pro cannot turn telemetry fully off. `AllowTelemetry=0` is treated as "Required", the lowest level those editions allow.

## What it changes

| Area | Change |
|---|---|
| Diagnostic data | `AllowTelemetry=0`, limits diagnostic log and dump collection, hides feedback notifications |
| Advertising | Disables the advertising ID and tailored experiences |
| Activity history | Disables `EnableActivityFeed`, `PublishUserActivities` and `UploadUserActivities` |
| Feedback prompts | Zeroes the `Siuf` feedback frequency values |
| Services | Stops and disables `DiagTrack` and `dmwappushservice` |
| Scheduled tasks | Disables the Compatibility Appraiser (including the `Exp` variant), CEIP tasks, Autochk Proxy, Siuf feedback tasks and the disk diagnostic collector |
| Optional (`-NoErrorReporting`) | Disables Windows Error Reporting and its queue task |

The script skips any service or task that doesn't exist on your build.

## Requirements

- Windows 11 (tested on 25H2, build 26200)
- Windows PowerShell 5.1 or later
- An elevated PowerShell session for `-Disable` and `-Restore`. `-Status` runs without elevation.

## Usage

```powershell
# Allow the script for this session only
Set-ExecutionPolicy Bypass -Scope Process -Force

# Preview without changing anything
.\Disable-Telemetry.ps1 -Disable -WhatIf

# Apply
.\Disable-Telemetry.ps1 -Disable

# Check current state
.\Disable-Telemetry.ps1 -Status

# Undo everything recorded in the state file
.\Disable-Telemetry.ps1 -Restore
```

Add `-NoErrorReporting` to `-Disable` to also turn off Windows Error Reporting.

Reboot after `-Disable`, then run `-Status`. Every registry value should match its target, both services should be Stopped and Disabled, and every task should be Disabled.

## How restore works

Before each change, the script saves the original registry values, service start types and task states to `C:\ProgramData\TelemetryToggle\state.json`. `-Restore` reads that file, reverts each item, and archives the file as `state-restored-<timestamp>.json`. Keep the state file until you're sure you won't need it.

## Warnings

- **Managed devices:** Don't use this on corporate or managed PCs. Defender for Endpoint, Intune and similar tools can depend on `DiagTrack` and the diagnostic data level.
- **Diagnostic Data Viewer:** With `DiagTrack` disabled, the viewer and its "Delete diagnostic data" button stop working. Delete your data first if you want to.
- **Windows Insider and Feedback Hub:** Both need diagnostic data.
- **Feature updates:** Disabling the Compatibility Appraiser can delay or stall them. If an update gets stuck, re-enable that task.
- **Activity history:** Turning it off removes cross-device activity features.
- **Per-user values:** HKCU values apply only to the account that runs the script.
- **Updates can undo changes:** Feature updates may re-enable tasks and services. Re-run `-Status`, and `-Disable` if anything drifted.
- **Verify on your build:** Registry value names and task paths come from Microsoft's documented policy names and community research. Confirm them with `-Status`.
- **Restore point:** Create one first with `Checkpoint-Computer -Description "pre-telemetry"`.

## Troubleshooting

- **"Running scripts is disabled on this system":** Use the `Set-ExecutionPolicy Bypass -Scope Process` line above, or run `powershell.exe -ExecutionPolicy Bypass -File .\Disable-Telemetry.ps1 -Status`.
- **A task shows as absent:** It doesn't exist on your build. The script logs this and moves on.
- **Windows Update misbehaves after applying:** Run `-Restore`, reboot and retest.

## License

MIT. See [LICENSE](LICENSE).

## Disclaimer

This script modifies system services, scheduled tasks and registry policy. It is provided as-is with no warranty. Test on a non-critical machine first and use at your own risk.
