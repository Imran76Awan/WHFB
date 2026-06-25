<#
.SYNOPSIS
    Remediates a missing, expired, or broken Primary Refresh Token (PRT).

.DESCRIPTION
    Staged 6-step remediation sequence with colour-coded output.
    Each step checks whether the PRT is restored before proceeding to the next.

    Step 1 — Restart TokenBroker service (clears stale token state)
    Step 2 — dsregcmd /refreshprt (standard PRT refresh)
    Step 3 — Trigger Automatic-Device-Join scheduled task (re-establishes hybrid join)
    Step 4 — Clear WAM token cache from registry, then re-run /refreshprt
    Step 5 — dsregcmd /debug /refreshprt (verbose, more thorough internal refresh)
    Step 6 — dsregcmd /forcerecovery (aggressive — only if Steps 1-5 fail)
    Step 7 — Diagnostic snapshot with root cause identification for escalation

    Colour scheme: green = OK, cyan = ACTION, yellow = WARN, red = FAIL, gray = INFO

.NOTES
    Intune Remediation — Remediation Script
    Run As  : Logged-on user (NOT System)
    Platform: Windows 10/11, Hybrid AAD or Azure AD Joined
    Exit 0  : Success — PRT obtained
    Exit 1  : Failed  — manual investigation required
    Log     : %LOCALAPPDATA%\PRT-Repair\
#>

$logLines = [System.Collections.Generic.List[string]]::new()
$logDir   = "$env:LOCALAPPDATA\PRT-Repair"
$logFile  = "$logDir\PRT-Remediate_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $logLines.Add($line)
    $color = switch ($Level) {
        'OK'     { 'Green' }
        'FAIL'   { 'Red' }
        'WARN'   { 'Yellow' }
        'ACTION' { 'Cyan' }
        default  { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Get-DsregValue {
    param([string[]]$Lines, [string]$Key)
    $line = $Lines | Where-Object { $_ -match "^\s+$Key\s*:" } | Select-Object -First 1
    if ($line) { return ($line -split ':', 2)[1].Trim() }
    return $null
}

function Get-PRTStatus {
    $out = & dsregcmd /status 2>&1
    return (Get-DsregValue -Lines $out -Key 'AzureAdPrt')
}

function Get-FullDsregStatus {
    $out = & dsregcmd /status 2>&1
    return [PSCustomObject]@{
        AzureAdJoined = Get-DsregValue -Lines $out -Key 'AzureAdJoined'
        DomainJoined  = Get-DsregValue -Lines $out -Key 'DomainJoined'
        AzureAdPrt    = Get-DsregValue -Lines $out -Key 'AzureAdPrt'
        TenantId      = Get-DsregValue -Lines $out -Key 'TenantId'
        DeviceId      = Get-DsregValue -Lines $out -Key 'DeviceId'
        PrtUpdateTime = Get-DsregValue -Lines $out -Key 'AzureAdPrtUpdateTime'
        PrtExpiryTime = Get-DsregValue -Lines $out -Key 'AzureAdPrtExpiryTime'
    }
}

function Save-Log {
    try {
        $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        $logLines | Set-Content -Path $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

try {
    Write-Log "PRT Remediation started — $env:COMPUTERNAME — User: $env:USERNAME" 'ACTION'
    Write-Log "------------------------------------------------------------" 'INFO'

    # Bail early if PRT is already valid
    if ((Get-PRTStatus) -eq 'YES') {
        Write-Log "PRT already valid — no remediation required." 'OK'
        Save-Log
        exit 0
    }

    Write-Log "PRT missing or expired — starting staged remediation..." 'WARN'
    Write-Log "" 'INFO'

    # =========================================================================
    # STEP 1 — Restart TokenBroker service
    # Clears stale in-memory token state that can block PRT issuance
    # =========================================================================
    Write-Log "STEP 1 — Restarting TokenBroker service..." 'ACTION'
    try {
        $svc = Get-Service -Name 'TokenBroker' -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Restart-Service -Name 'TokenBroker' -Force -ErrorAction Stop
            Write-Log "STEP 1 — TokenBroker restarted successfully" 'OK'
        } else {
            Start-Service -Name 'TokenBroker' -ErrorAction Stop
            Write-Log "STEP 1 — TokenBroker started (was stopped)" 'OK'
        }
        Start-Sleep -Seconds 5
    } catch {
        Write-Log "STEP 1 — TokenBroker restart skipped: $($_.Exception.Message)" 'WARN'
    }

    # =========================================================================
    # STEP 2 — dsregcmd /refreshprt
    # Standard PRT refresh — works for most stale or expired PRT cases
    # =========================================================================
    Write-Log "STEP 2 — Running dsregcmd /refreshprt..." 'ACTION'
    & dsregcmd /refreshprt 2>&1 | Out-Null
    Start-Sleep -Seconds 15

    if ((Get-PRTStatus) -eq 'YES') {
        Write-Log "STEP 2 — SUCCESS: PRT obtained via dsregcmd /refreshprt" 'OK'
        Save-Log
        exit 0
    }
    Write-Log "STEP 2 — PRT still missing after /refreshprt. Continuing..." 'WARN'

    # =========================================================================
    # STEP 3 — Trigger Automatic-Device-Join scheduled task
    # Re-establishes the hybrid join device registration state that unblocks PRT
    # =========================================================================
    Write-Log "STEP 3 — Triggering Automatic-Device-Join scheduled task..." 'ACTION'
    try {
        $taskPath = '\Microsoft\Windows\Workplace Join\'
        $taskName = 'Automatic-Device-Join'
        Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
        Write-Log "STEP 3 — Automatic-Device-Join task triggered. Waiting 30s..." 'ACTION'
        Start-Sleep -Seconds 30

        # Follow up with a PRT refresh now that join state is refreshed
        & dsregcmd /refreshprt 2>&1 | Out-Null
        Start-Sleep -Seconds 10

        if ((Get-PRTStatus) -eq 'YES') {
            Write-Log "STEP 3 — SUCCESS: PRT obtained after Automatic-Device-Join + refresh" 'OK'
            Save-Log
            exit 0
        }
        Write-Log "STEP 3 — PRT still missing. Continuing..." 'WARN'
    } catch {
        Write-Log "STEP 3 — Automatic-Device-Join task unavailable: $($_.Exception.Message)" 'WARN'
    }

    # =========================================================================
    # STEP 4 — Clear WAM token cache from registry, then re-refresh
    # Removes stale cached tokens that can prevent new PRT acquisition
    # =========================================================================
    Write-Log "STEP 4 — Clearing WAM token cache from registry..." 'ACTION'
    $wamCleared = $false

    try {
        # AAD primary token cache
        $aadPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AAD"
        if (Test-Path "$aadPath\PR0") {
            Get-ChildItem "$aadPath\PR0" -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Log "STEP 4 — WAM AAD (PR0) cache entries cleared" 'OK'
            $wamCleared = $true
        }

        # IdentityCRL TokenBroker account cache — remove only Azure AD entries
        $idPath = "HKCU:\Software\Microsoft\IdentityCRL\TokenBroker\Accounts"
        if (Test-Path $idPath) {
            Get-ChildItem $idPath -ErrorAction SilentlyContinue | ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($props.Authority -like '*microsoftonline*' -or $props.Authority -like '*windows.net*') {
                    Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                    $wamCleared = $true
                }
            }
            Write-Log "STEP 4 — IdentityCRL Azure AD token entries cleared" 'OK'
        }

        if (-not $wamCleared) {
            Write-Log "STEP 4 — No WAM cache entries found to clear" 'WARN'
        }
    } catch {
        Write-Log "STEP 4 — WAM cache clear error: $($_.Exception.Message)" 'WARN'
    }

    # Re-run refresh after cache clear
    Write-Log "STEP 4 — Running dsregcmd /refreshprt after cache clear..." 'ACTION'
    & dsregcmd /refreshprt 2>&1 | Out-Null
    Start-Sleep -Seconds 15

    if ((Get-PRTStatus) -eq 'YES') {
        Write-Log "STEP 4 — SUCCESS: PRT obtained after WAM cache clear + refresh" 'OK'
        Save-Log
        exit 0
    }
    Write-Log "STEP 4 — PRT still missing. Continuing..." 'WARN'

    # =========================================================================
    # STEP 5 — dsregcmd /debug /refreshprt
    # More thorough internal refresh with verbose diagnostic output
    # =========================================================================
    Write-Log "STEP 5 — Running dsregcmd /debug /refreshprt (verbose)..." 'ACTION'
    & dsregcmd /debug /refreshprt 2>&1 | Out-Null
    Start-Sleep -Seconds 20

    if ((Get-PRTStatus) -eq 'YES') {
        Write-Log "STEP 5 — SUCCESS: PRT obtained via dsregcmd /debug /refreshprt" 'OK'
        Save-Log
        exit 0
    }
    Write-Log "STEP 5 — PRT still missing. Attempting force recovery..." 'WARN'

    # =========================================================================
    # STEP 6 — dsregcmd /forcerecovery
    # Aggressive: cleans up device registration state and re-triggers join.
    # Only runs when all previous steps have failed.
    # =========================================================================
    Write-Log "STEP 6 — Running dsregcmd /forcerecovery (aggressive)..." 'ACTION'
    Write-Log "STEP 6 — This resets device registration state and re-triggers hybrid join" 'WARN'
    try {
        & dsregcmd /forcerecovery 2>&1 | Out-Null
        Write-Log "STEP 6 — Force recovery complete. Waiting 30s for re-registration..." 'ACTION'
        Start-Sleep -Seconds 30

        # Re-trigger device join after recovery
        try {
            Start-ScheduledTask -TaskPath '\Microsoft\Windows\Workplace Join\' -TaskName 'Automatic-Device-Join' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 20
        } catch {}

        # Final PRT refresh attempt
        & dsregcmd /refreshprt 2>&1 | Out-Null
        Start-Sleep -Seconds 15

        if ((Get-PRTStatus) -eq 'YES') {
            Write-Log "STEP 6 — SUCCESS: PRT obtained after force recovery" 'OK'
            Save-Log
            exit 0
        }
        Write-Log "STEP 6 — PRT still missing after force recovery" 'FAIL'
    } catch {
        Write-Log "STEP 6 — Force recovery error: $($_.Exception.Message)" 'FAIL'
    }

    # =========================================================================
    # STEP 7 — All steps exhausted — collect diagnostics for escalation
    # =========================================================================
    Write-Log "" 'INFO'
    Write-Log "------------------------------------------------------------" 'INFO'
    Write-Log "STEP 7 — All remediation steps exhausted. Collecting diagnostics..." 'ACTION'

    $status = Get-FullDsregStatus

    Write-Log "--- Diagnostic Snapshot ---" 'INFO'
    Write-Log "AzureAdJoined  : $($status.AzureAdJoined)" 'INFO'
    Write-Log "DomainJoined   : $($status.DomainJoined)" 'INFO'
    Write-Log "AzureAdPrt     : $($status.AzureAdPrt)" 'INFO'
    Write-Log "TenantId       : $($status.TenantId)" 'INFO'
    Write-Log "DeviceId       : $($status.DeviceId)" 'INFO'
    Write-Log "PrtUpdateTime  : $($status.PrtUpdateTime)" 'INFO'
    Write-Log "PrtExpiryTime  : $($status.PrtExpiryTime)" 'INFO'
    Write-Log "---------------------------" 'INFO'

    # Root cause identification
    if ($status.AzureAdJoined -ne 'YES') {
        Write-Log "ROOT CAUSE: Device is not Azure AD Joined — AAD Connect sync or hybrid join registration likely broken" 'FAIL'
    } elseif ($status.DomainJoined -ne 'YES') {
        Write-Log "ROOT CAUSE: Device is not Domain Joined — check network connectivity to domain controllers" 'FAIL'
    } elseif (-not $status.TenantId) {
        Write-Log "ROOT CAUSE: No TenantId found — device may not be synced to Azure AD via AAD Connect" 'FAIL'
    } elseif (-not $status.DeviceId) {
        Write-Log "ROOT CAUSE: No DeviceId found — device object may be missing or disabled in Azure AD" 'FAIL'
    } else {
        Write-Log "ROOT CAUSE: Undetermined — device join state intact but PRT unobtainable. Check Conditional Access, network (ADFS/PTA/PHS), and DC line-of-sight" 'FAIL'
    }

    Write-Log "------------------------------------------------------------" 'INFO'
    Write-Log "RESULT: FAILED — PRT remediation unsuccessful. Manual investigation required." 'FAIL'
    Write-Log "Log saved to: $logFile" 'FAIL'

    Save-Log
    exit 1

} catch {
    Write-Log "ERROR: Unhandled exception — $($_.Exception.Message)" 'FAIL'
    Save-Log
    exit 1
}
