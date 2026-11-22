<#
.SYNOPSIS
    Reduces Windows 11 telemetry, tracking and feedback prompts. Reversible.

.DESCRIPTION
    Applies, in one pass:
      1. Policy registry values (diagnostic data level, log/dump limits,
         advertising ID, tailored experiences, activity history, feedback prompts)
      2. Disables the DiagTrack and dmwappushservice services
      3. Disables telemetry-related scheduled tasks (CEIP, Appraiser, Siuf, etc.)

    Original values are recorded to a state file so -Restore can put everything
    back. Nothing runs on a timer; re-run -Disable after feature updates.

.PARAMETER Disable
    Apply the changes.

.PARAMETER Restore
    Revert everything recorded in the state file.

.PARAMETER Status
    Report current values, services and tasks. Changes nothing, no admin needed.

.PARAMETER NoErrorReporting
    Also disable Windows Error Reporting and its queue task. Off by default
    because you lose crash dumps and "a fix is available" prompts.

.EXAMPLE
    .\Disable-Telemetry.ps1 -Disable -WhatIf
.EXAMPLE
    .\Disable-Telemetry.ps1 -Disable
.EXAMPLE
    .\Disable-Telemetry.ps1 -Status
.EXAMPLE
    .\Disable-Telemetry.ps1 -Restore

.NOTES
    WARNINGS
      - Home/Pro cannot turn telemetry fully off. AllowTelemetry=0 is treated as
        "Required", the lowest level those editions allow.
      - Do NOT use on managed/corporate devices. Defender for Endpoint, Intune
        and similar tools can depend on DiagTrack and the diagnostic data level.
      - With DiagTrack disabled the Diagnostic Data Viewer and its "Delete
        diagnostic data" button stop working. Delete your data first if wanted.
      - Windows Insider builds and Feedback Hub need diagnostic data.
      - Disabling the Compatibility Appraiser can delay or stall feature
        updates. Re-enable that task if an update gets stuck.
      - Turning off activity history removes cross-device activity features.
      - HKCU values apply only to the account that runs this script.
      - Feature updates can re-enable tasks/services. Check with -Status.
      - Registry value names and task paths are from Microsoft's documented
        policy names and community research; verify on your build with -Status.
      - Make a restore point first: Checkpoint-Computer -Description "pre-telemetry"

    Requires: Windows PowerShell 5.1+, elevated session for -Disable/-Restore.

#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Disable,
    [switch]$Restore,
    [switch]$Status,
    [switch]$NoErrorReporting
)

# ----------------------------------------------------------------- configuration

$Script:Dir       = Join-Path $env:ProgramData 'TelemetryToggle'
$Script:StateFile = Join-Path $Script:Dir 'state.json'

$dc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
$sy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'

$Script:RegValues = @(
    # Diagnostic data level. 0 = Enterprise "Security"; Home/Pro treat it as Required.
    @{ P = $dc; N = 'AllowTelemetry';                 V = 0; T = 'DWord' }
    @{ P = $dc; N = 'LimitDiagnosticLogCollection';   V = 1; T = 'DWord' }
    @{ P = $dc; N = 'LimitDumpCollection';            V = 1; T = 'DWord' }
    @{ P = $dc; N = 'DoNotShowFeedbackNotifications'; V = 1; T = 'DWord' }

    # Advertising ID and tailored experiences
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; N = 'DisabledByGroupPolicy'; V = 1; T = 'DWord' }
    @{ P = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';    N = 'DisableTailoredExperiencesWithDiagnosticData'; V = 1; T = 'DWord' }

    # Activity history
    @{ P = $sy; N = 'EnableActivityFeed';    V = 0; T = 'DWord' }
    @{ P = $sy; N = 'PublishUserActivities'; V = 0; T = 'DWord' }
    @{ P = $sy; N = 'UploadUserActivities';  V = 0; T = 'DWord' }

    # Feedback prompts ("How are we doing?")
    @{ P = 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules'; N = 'NumberOfSIUFInPeriod';  V = 0; T = 'DWord' }
    @{ P = 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules'; N = 'PeriodInNanoSeconds';   V = 0; T = 'QWord' }
)

$Script:Services = @('DiagTrack', 'dmwappushservice')

$Script:Tasks = @(
    # Appraiser: older builds use the first name, newer builds use the "Exp" variant.
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser Exp'
    '\Microsoft\Windows\Autochk\Proxy'
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
    '\Microsoft\Windows\Feedback\Siuf\DmClient'
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
)

# ProgramDataUpdater is intentionally left alone: it feeds app-compatibility shims.

if ($NoErrorReporting) {
    $Script:RegValues += @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; N = 'Disabled'; V = 1; T = 'DWord' }
    $Script:Tasks     += '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
}

# ------------------------------------------------------------------------ helpers

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'STEP' { 'Cyan' } default { 'Gray' } }
    Write-Host ('[{0}] {1}' -f $Level, $Message) -ForegroundColor $color
}

function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run from an elevated PowerShell (Run as administrator).'
    }
}

function Get-State {
    if (Test-Path $Script:StateFile) { return Get-Content $Script:StateFile -Raw | ConvertFrom-Json }
    [pscustomobject]@{ Created = (Get-Date).ToUniversalTime().ToString('o'); Computer = $env:COMPUTERNAME; Reg = @(); Svc = @(); Task = @() }
}

function Split-TaskPath {
    param([string]$Full)
    [pscustomobject]@{ Path = ((Split-Path $Full -Parent) + '\'); Name = (Split-Path $Full -Leaf) }
}

# --------------------------------------------------------------------------- status

function Show-Status {
    Write-Host "`n=== Telemetry toggle: status ===" -ForegroundColor Cyan
    Write-Host 'Registry:'
    foreach ($r in $Script:RegValues) {
        $v = (Get-ItemProperty -Path $r.P -Name $r.N -ErrorAction SilentlyContinue).($r.N)
        $ok = ($null -ne $v -and $v -eq $r.V)
        Write-Host ('  {0,-46} {1,-8} (want {2})' -f $r.N, $(if ($null -eq $v) { 'unset' } else { $v }), $r.V) -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
    }
    Write-Host 'Services:'
    Get-Service $Script:Services -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
    Write-Host 'Tasks:'
    foreach ($t in $Script:Tasks) {
        $s = Split-TaskPath $t
        $o = Get-ScheduledTask -TaskPath $s.Path -TaskName $s.Name -ErrorAction SilentlyContinue
        if ($o) { Write-Host ('  {0,-9} {1}' -f $o.State, $t) -ForegroundColor $(if ($o.State -eq 'Disabled') { 'Green' } else { 'Yellow' }) }
        else    { Write-Host ('  absent    {0}' -f $t) -ForegroundColor DarkGray }
    }
    Write-Host ''
}

# -------------------------------------------------------------------------- disable

function Invoke-Disable {
    $state = Get-State

    Write-Log 'Applying policy values' 'STEP'
    foreach ($r in $Script:RegValues) {
        $cur = (Get-ItemProperty -Path $r.P -Name $r.N -ErrorAction SilentlyContinue).($r.N)
        if (-not ($state.Reg | Where-Object { $_.P -eq $r.P -and $_.N -eq $r.N })) {
            $state.Reg += [pscustomobject]@{ P = $r.P; N = $r.N; T = $r.T; Existed = ($null -ne $cur); Old = $cur }
        }
        if ($PSCmdlet.ShouldProcess("$($r.P)\$($r.N)", "Set $($r.V)")) {
            try {
                if (-not (Test-Path $r.P)) { New-Item -Path $r.P -Force | Out-Null }
                New-ItemProperty -Path $r.P -Name $r.N -Value $r.V -PropertyType $r.T -Force -ErrorAction Stop | Out-Null
            } catch { Write-Log "Failed $($r.P)\$($r.N): $($_.Exception.Message)" 'ERROR' }
        }
    }

    Write-Log 'Disabling services' 'STEP'
    foreach ($n in $Script:Services) {
        $v = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $v) { Write-Log "$n not present, skipping." 'INFO'; continue }
        if (-not ($state.Svc | Where-Object { $_.Name -eq $n })) {
            $state.Svc += [pscustomobject]@{ Name = $n; Start = $v.StartType.ToString(); Running = ($v.Status -eq 'Running') }
        }
        if ($PSCmdlet.ShouldProcess($n, 'Stop and disable')) {
            try { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue; Set-Service -Name $n -StartupType Disabled -ErrorAction Stop }
            catch { Write-Log "Failed $n : $($_.Exception.Message)" 'ERROR' }
        }
    }

    Write-Log 'Disabling scheduled tasks' 'STEP'
    foreach ($t in $Script:Tasks) {
        $s = Split-TaskPath $t
        $o = Get-ScheduledTask -TaskPath $s.Path -TaskName $s.Name -ErrorAction SilentlyContinue
        if (-not $o) { Write-Log "Task not present: $t" 'INFO'; continue }
        if (-not ($state.Task | Where-Object { $_.Path -eq $t })) {
            $state.Task += [pscustomobject]@{ Path = $t; WasEnabled = ($o.State -ne 'Disabled') }
        }
        if ($PSCmdlet.ShouldProcess($t, 'Disable task')) {
            try { Disable-ScheduledTask -TaskPath $s.Path -TaskName $s.Name -ErrorAction Stop | Out-Null }
            catch { Write-Log "Failed $t : $($_.Exception.Message)" 'ERROR' }
        }
    }

    if (-not $WhatIfPreference) {
        if (-not (Test-Path $Script:Dir)) { New-Item -Path $Script:Dir -ItemType Directory -Force | Out-Null }
        $state | ConvertTo-Json -Depth 6 | Set-Content -Path $Script:StateFile -Encoding UTF8
        Write-Log "State saved to $Script:StateFile" 'OK'
        Write-Log 'Done. Reboot, run -Status, and re-run -Disable after feature updates.' 'OK'
    } else {
        Write-Log 'WhatIf: nothing was changed or saved.' 'WARN'
    }
}

# -------------------------------------------------------------------------- restore

function Invoke-Restore {
    if (-not (Test-Path $Script:StateFile)) { Write-Log "No state file at $Script:StateFile - nothing to restore." 'WARN'; return }
    $state = Get-State

    Write-Log 'Reverting policy values' 'STEP'
    foreach ($e in $state.Reg) {
        if (-not $PSCmdlet.ShouldProcess("$($e.P)\$($e.N)", 'Revert')) { continue }
        try {
            if ($e.Existed) { New-ItemProperty -Path $e.P -Name $e.N -Value $e.Old -PropertyType $e.T -Force -ErrorAction Stop | Out-Null }
            else            { Remove-ItemProperty -Path $e.P -Name $e.N -ErrorAction SilentlyContinue }
        } catch { Write-Log "Failed $($e.P)\$($e.N): $($_.Exception.Message)" 'ERROR' }
    }

    Write-Log 'Restoring services' 'STEP'
    foreach ($e in $state.Svc) {
        if (-not $PSCmdlet.ShouldProcess($e.Name, "Restore start type $($e.Start)")) { continue }
        try {
            Set-Service -Name $e.Name -StartupType $e.Start -ErrorAction Stop
            if ($e.Running) { Start-Service -Name $e.Name -ErrorAction SilentlyContinue }
        } catch { Write-Log "Failed $($e.Name): $($_.Exception.Message)" 'ERROR' }
    }

    Write-Log 'Restoring scheduled tasks' 'STEP'
    foreach ($e in $state.Task) {
        if (-not $e.WasEnabled) { continue }
        $s = Split-TaskPath $e.Path
        if ($PSCmdlet.ShouldProcess($e.Path, 'Enable task')) {
            try { Enable-ScheduledTask -TaskPath $s.Path -TaskName $s.Name -ErrorAction Stop | Out-Null }
            catch { Write-Log "Failed $($e.Path): $($_.Exception.Message)" 'ERROR' }
        }
    }

    if (-not $WhatIfPreference) {
        $archive = Join-Path $Script:Dir ('state-restored-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -Path $Script:StateFile -Destination $archive -Force
        Write-Log "Restore complete. State archived to $archive" 'OK'
    }
}

# ----------------------------------------------------------------------------- main

if ($Disable -and $Restore) { throw 'Use -Disable or -Restore, not both.' }

if ($Status -or (-not $Disable -and -not $Restore)) {
    Show-Status
    if (-not $Status) {
        Write-Host 'Usage: .\Disable-Telemetry.ps1 [-Disable | -Restore | -Status] [-NoErrorReporting] [-WhatIf]' -ForegroundColor Cyan
    }
    return
}

Assert-Admin
if ($Disable) { Invoke-Disable } else { Invoke-Restore }
