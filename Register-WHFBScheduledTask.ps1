<#
.SYNOPSIS
    Registers a scheduled task that runs the WHfB enrollment check at every logon.

.DESCRIPTION
    Creates a per-user logon task that:
      - Runs Invoke-WHFBEnrollmentCheck.ps1 for the interactive user
      - Waits 60 seconds after logon (gives the PRT time to refresh)
      - Re-prompts at each logon until NgcSet = YES (exit 0), then stops re-prompting

    Must be run once as a LOCAL ADMINISTRATOR (e.g. via Intune remediation script
    targeting SYSTEM, or manually by an admin).

.PARAMETER ScriptPath
    Full path to Invoke-WHFBEnrollmentCheck.ps1.
    Defaults to the same folder as this script.

.PARAMETER TaskName
    Name of the scheduled task. Default: 'WHfB-EnrollmentCheck'
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ScriptPath = '',
    [string]$TaskName   = 'WHfB-EnrollmentCheck'
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty when used in a param() default in some execution contexts
if (-not $ScriptPath) {
    $scriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $ScriptPath = Join-Path $scriptDir 'Invoke-WHFBEnrollmentCheck.ps1'
}

if (-not (Test-Path $ScriptPath)) {
    Write-Error "Script not found: $ScriptPath"
    exit 1
}

# Remove any existing task with the same name
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Action: run PowerShell as the logged-on user
$psExe  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction `
    -Execute $psExe `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""

# Trigger: at logon of any user, with a 60-second delay for PRT hydration
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = 'PT60S'   # ISO 8601 duration

# Principal: run as the interactive user (not SYSTEM) so dsregcmd sees user context
# GroupId S-1-5-32-545 = BUILTIN\Users (runs as the logged-on user, not SYSTEM)
$principal = New-ScheduledTaskPrincipal `
    -GroupId 'S-1-5-32-545' `
    -RunLevel Limited

# Settings: only run if user is logged on; allow on battery; no time limit
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

$task = Register-ScheduledTask `
    -TaskName  $TaskName `
    -Action    $action `
    -Trigger   $trigger `
    -Principal $principal `
    -Settings  $settings `
    -Description 'Checks WHfB enrollment status at logon; prompts user to enroll if PRT present but NgcSet=NO.' `
    -Force

Write-Host "Scheduled task '$($task.TaskName)' registered successfully." -ForegroundColor Green
Write-Host "It will run 60 seconds after each user logon until WHfB is enrolled."
