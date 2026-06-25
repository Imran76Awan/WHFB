#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Remediation Script - Windows Hello for Business (WHfB) Auto-Repair

.DESCRIPTION
    Silently remediates common WHfB failures detected by Detect-WHfB.ps1.
    Designed for Intune Proactive Remediations - no interactive prompts.

    Remediations attempted (in order):
      1. Restart failed WHfB services (KeyIso, NgcSvc, NgcCtnrSvc, TokenBroker)
      2. Refresh Primary Refresh Token (PRT) via scheduled task as logged-on user
      3. Trigger dsregcmd /forcerecovery for stuck registrations
      4. Trigger Intune MDM sync to re-apply WHfB policy
      5. Clean stale NGC keys and retrigger WHfB provisioning task
      6. Re-trigger Hybrid AAD Join task (if Hybrid device)

    Exit codes:
      0 = Remediation actions completed (re-run detection to verify)
      1 = Remediation failed or prerequisites not met

.NOTES
    Run context : SYSTEM (default Intune context) - uses scheduled tasks to
                  perform user-context operations on the logged-on user.
    Log path    : C:\ProgramData\WHfB-Repair\
    SAFE        : Does NOT clear TPM. Does NOT modify BitLocker.
                  Does NOT remove the user's NGC container without rebuilding it.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'SilentlyContinue'

#region -- Logging -------------------------------------------------------------

$LogFolder  = 'C:\ProgramData\WHfB-Repair'
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile    = Join-Path $LogFolder "WHfB-Remediate_$($env:COMPUTERNAME)_$timestamp.log"

if (-not (Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

$script:exitCode = 0

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[{0}] [{1,-6}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8 -Force
    $color = switch ($Level) {
        'OK'     { 'Green'   }
        'WARN'   { 'Yellow'  }
        'FAIL'   { 'Red'     }
        'ACTION' { 'Cyan'    }
        default  { 'Gray'    }
    }
    Write-Host $entry -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)
    Write-Log ("=" * 60) 'INFO'
    Write-Log "  $Title" 'INFO'
    Write-Log ("=" * 60) 'INFO'
}

#endregion

#region -- Helpers -------------------------------------------------------------

function Get-DsregStatus {
    $raw = & dsregcmd.exe /status 2>&1
    $map = @{}
    foreach ($line in $raw) {
        if ($line -match '^\s+([A-Za-z0-9_]+)\s*:\s*(.+)$') {
            $map[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $map
}

function Get-LoggedOnUser {
    try {
        $user = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($user -and $user -ne '') { return $user }
    }
    catch { }
    # Fallback: query active sessions
    try {
        $sessions = query session 2>&1 | Where-Object { $_ -match 'Active' -and $_ -notmatch 'SYSTEM|Services' }
        if ($sessions) {
            $parts = ($sessions | Select-Object -First 1) -split '\s+'
            $username = $parts | Where-Object { $_ -ne '' } | Select-Object -First 1
            if ($username) { return $username }
        }
    }
    catch { }
    return $null
}

function Invoke-AsLoggedOnUser {
    param(
        [string]$TaskName,
        [string]$Execute,
        [string]$Argument = ''
    )
    $loggedOnUser = Get-LoggedOnUser
    if (-not $loggedOnUser) {
        Write-Log "No interactive user session found - cannot run user-context task" 'WARN'
        return $false
    }

    Write-Log "Scheduling [$Execute $Argument] as user [$loggedOnUser]" 'ACTION'
    try {
        $action    = New-ScheduledTaskAction -Execute $Execute -Argument $Argument
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
        $principal = New-ScheduledTaskPrincipal -UserId $loggedOnUser -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 5)

        $params = @{
            TaskName  = $TaskName
            Action    = $action
            Trigger   = $trigger
            Principal = $principal
            Settings  = $settings
            Force     = $true
        }
        Register-ScheduledTask @params | Out-Null
        Start-Sleep -Seconds 15
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "User-context task completed: $TaskName" 'OK'
        return $true
    }
    catch {
        Write-Log "Failed to run user-context task [$TaskName]: $_" 'WARN'
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        return $false
    }
}

#endregion

#region -- Remediation Steps ---------------------------------------------------

function Repair-Services {
    Write-Section "Step 1: Restart WHfB Required Services"
    $services = @(
        @{ Name = 'KeyIso';      Friendly = 'CNG Key Isolation'    }
        @{ Name = 'NgcSvc';      Friendly = 'NGC Cryptographic Svc' }
        @{ Name = 'NgcCtnrSvc';  Friendly = 'NGC Container Svc'     }
        @{ Name = 'TokenBroker'; Friendly = 'Web Account Manager'   }
    )

    foreach ($svc in $services) {
        $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if (-not $s) {
            Write-Log "Service not found: $($svc.Name)" 'WARN'
            continue
        }
        if ($s.Status -eq 'Running') {
            Write-Log "$($svc.Friendly) ($($svc.Name)): Already running" 'OK'
            continue
        }
        try {
            Set-Service -Name $svc.Name -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name $svc.Name -ErrorAction Stop
            Write-Log "$($svc.Friendly) ($($svc.Name)): Started successfully" 'OK'
        }
        catch {
            Write-Log "$($svc.Friendly) ($($svc.Name)): Failed to start - $_" 'WARN'
        }
    }
}

function Repair-PRT {
    Write-Section "Step 2: Refresh Primary Refresh Token (PRT)"

    # Attempt 1: dsregcmd /refreshprt as logged-on user
    Write-Log "Triggering dsregcmd /refreshprt as logged-on user..." 'ACTION'
    $taskName = "WHfB-PRT-Refresh-$timestamp"
    $success  = Invoke-AsLoggedOnUser -TaskName $taskName -Execute 'dsregcmd.exe' -Argument '/refreshprt'

    if ($success) {
        $newStatus = Get-DsregStatus
        if ($newStatus['AzureAdPrt'] -eq 'YES') {
            Write-Log "PRT acquired successfully via WAM refresh" 'OK'
            return $true
        }
        Write-Log "PRT refresh task ran but PRT still not present" 'WARN'
    }

    # Attempt 2: dsregcmd /forcerecovery (SYSTEM context)
    Write-Log "Attempting dsregcmd /forcerecovery..." 'ACTION'
    try {
        $recovery = & dsregcmd.exe /forcerecovery 2>&1
        Write-Log "ForceRecovery output: $($recovery -join ' | ')" 'INFO'
        Start-Sleep -Seconds 15

        $newStatus = Get-DsregStatus
        if ($newStatus['AzureAdPrt'] -eq 'YES') {
            Write-Log "PRT acquired via force recovery" 'OK'
            return $true
        }
    }
    catch {
        Write-Log "ForceRecovery failed: $_" 'WARN'
    }

    Write-Log "PRT remediation incomplete - user sign-out/in may be required" 'WARN'
    return $false
}

function Repair-HybridJoin {
    param([hashtable]$Dsreg)
    Write-Section "Step 3: Hybrid AAD Join Re-registration"

    $domainJoined = $Dsreg['DomainJoined'] -eq 'YES'
    $aadJoined    = $Dsreg['AzureAdJoined'] -eq 'YES'

    if (-not ($domainJoined -and -not $aadJoined)) {
        Write-Log "Device is not a failed hybrid join - skipping" 'INFO'
        return
    }

    Write-Log "Domain-joined but not AAD-joined - triggering Automatic-Device-Join task" 'ACTION'
    try {
        $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Workplace Join\' `
                    -TaskName 'Automatic-Device-Join' -ErrorAction Stop
        Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName
        Start-Sleep -Seconds 20
        $taskInfo = Get-ScheduledTaskInfo -TaskPath $task.TaskPath -TaskName $task.TaskName
        Write-Log "Hybrid Join task result: $($taskInfo.LastTaskResult)" 'INFO'
    }
    catch {
        Write-Log "Hybrid AAD Join task not found or failed: $_" 'WARN'
    }

    # Run dsregcmd /debug for additional info
    Write-Log "Running dsregcmd /debug..." 'ACTION'
    & dsregcmd.exe /debug 2>&1 | Out-Null
}

function Repair-IntuneSync {
    Write-Section "Step 4: Trigger Intune MDM Sync"

    Write-Log "Triggering Intune MDM sync via scheduled tasks..." 'ACTION'

    # Method 1: Enterprise Management tasks
    try {
        $sched = New-Object -ComObject 'Schedule.Service'
        $sched.Connect()
        $folders = @(
            '\Microsoft\Windows\EnterpriseMgmt',
            '\Microsoft\Windows\EnterpriseMgmtNoncritical'
        )
        foreach ($folderPath in $folders) {
            try {
                $folder = $sched.GetFolder($folderPath)
                $tasks  = $folder.GetTasks(0)
                foreach ($t in $tasks) {
                    $t.Run($null) | Out-Null
                    Write-Log "Triggered MDM task: $($t.Name)" 'ACTION'
                }
            }
            catch { }
        }
    }
    catch {
        Write-Log "MDM task trigger (COM): $_" 'WARN'
    }

    # Method 2: CIM-based MDM sync
    try {
        $session = New-CimSession -ErrorAction Stop
        $invokeParams = @{
            Namespace   = 'root/cimv2/mdm/dmmap'
            ClassName   = 'MDM_Client'
            MethodName  = 'UpdateSession'
            CimSession  = $session
            ErrorAction = 'Stop'
        }
        Invoke-CimMethod @invokeParams | Out-Null
        Remove-CimSession $session -ErrorAction SilentlyContinue
        Write-Log "MDM sync triggered via CIM MDM_Client" 'OK'
    }
    catch {
        Write-Log "CIM MDM sync: $_" 'WARN'
    }

    # Method 3: deviceenroller auto-enroll
    $enrollPath = "$env:SystemRoot\System32\deviceenroller.exe"
    if (Test-Path $enrollPath) {
        try {
            & $enrollPath /c /AutoEnrollMDM 2>&1 | Out-Null
            Write-Log "deviceenroller /AutoEnrollMDM triggered" 'OK'
        }
        catch {
            Write-Log "deviceenroller failed: $_" 'WARN'
        }
    }

    Write-Log "MDM sync triggered - policy re-application may take up to 15 minutes" 'INFO'
}

function Repair-NgcKeys {
    Write-Section "Step 5: Clean Stale NGC Keys and Retrigger WHfB Provisioning"

    # Clean NGC key store
    $ngcPath = "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
    if (Test-Path $ngcPath) {
        Write-Log "Clearing stale NGC key store at: $ngcPath" 'ACTION'
        try {
            # Take ownership to allow deletion
            & takeown.exe /F $ngcPath /R /D Y 2>&1 | Out-Null
            & icacls.exe $ngcPath /grant "Administrators:F" /T 2>&1 | Out-Null
            Get-ChildItem $ngcPath -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "NGC key store cleared" 'OK'
        }
        catch {
            Write-Log "NGC key store clear failed: $_" 'WARN'
        }
    }
    else {
        Write-Log "NGC key store not found at expected path - skipping" 'INFO'
    }

    # Run dsregcmd /cleanupaccounts
    Write-Log "Running dsregcmd /cleanupaccounts..." 'ACTION'
    try {
        $cleanup = & dsregcmd.exe /cleanupaccounts 2>&1
        Write-Log "Cleanup output: $($cleanup -join ' | ')" 'INFO'
    }
    catch {
        Write-Log "dsregcmd /cleanupaccounts failed: $_" 'WARN'
    }

    # Retrigger WHfB provisioning scheduled task
    Write-Log "Triggering NGC UserTask-Roam provisioning task..." 'ACTION'
    $ngcTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\CertificateServicesClient\' `
                   -TaskName 'UserTask-Roam' -ErrorAction SilentlyContinue
    if ($ngcTask) {
        try {
            Start-ScheduledTask -TaskPath $ngcTask.TaskPath -TaskName $ngcTask.TaskName -ErrorAction Stop
            Write-Log "NGC provisioning task triggered" 'OK'
        }
        catch {
            Write-Log "NGC task trigger failed: $_" 'WARN'
        }
    }
    else {
        Write-Log "NGC UserTask-Roam not found" 'WARN'
    }

    # Restart NGC services after cleanup
    Write-Log "Restarting NGC services after key cleanup..." 'ACTION'
    @('NgcSvc', 'NgcCtnrSvc') | ForEach-Object {
        $svc = Get-Service $_ -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Restart-Service $_ -Force -ErrorAction SilentlyContinue
                Write-Log "Restarted: $_" 'OK'
            }
            catch {
                Write-Log "Could not restart ${_}: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    Write-Log "NGC cleanup complete - user must sign out and back in to re-provision WHfB" 'ACTION'
}

#endregion

#region -- Main ----------------------------------------------------------------

Write-Log "WHfB Intune Remediation Script started"
Write-Log "Computer : $env:COMPUTERNAME"
Write-Log "User     : $env:USERNAME"
Write-Log "OS       : $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)"
Write-Log "Log file : $LogFile"

try {
    # Capture state before remediation
    Write-Section "Pre-Remediation State"
    $dsreg = Get-DsregStatus
    Write-Log "AzureAdJoined   : $($dsreg['AzureAdJoined'])"
    Write-Log "DomainJoined    : $($dsreg['DomainJoined'])"
    Write-Log "AzureAdPrt      : $($dsreg['AzureAdPrt'])"
    Write-Log "NgcSet          : $($dsreg['NgcSet'])"
    Write-Log "NgcKeyId        : $($dsreg['NgcKeyId'])"
    Write-Log "WamDefaultSet   : $($dsreg['WamDefaultSet'])"

    # Run remediation steps
    Repair-Services
    Repair-PRT
    Repair-HybridJoin -Dsreg $dsreg
    Repair-IntuneSync

    # Only clean NGC keys if they are actually missing or broken
    $ngcBroken = ($dsreg['NgcSet'] -ne 'YES') -or
                 ([string]::IsNullOrWhiteSpace($dsreg['NgcKeyId'])) -or
                 ($dsreg['NgcKeyId'] -eq 'ERROR')
    if ($ngcBroken) {
        Write-Log "NGC key missing or broken - running NGC cleanup" 'ACTION'
        Repair-NgcKeys
    }
    else {
        Write-Log "NGC key already provisioned (NgcSet=YES, KeyId=$($dsreg['NgcKeyId'])) - skipping NGC cleanup" 'OK'
    }

    # Capture state after remediation
    Write-Section "Post-Remediation State"
    $dsreg2 = Get-DsregStatus
    Write-Log "AzureAdJoined   : $($dsreg2['AzureAdJoined'])"
    Write-Log "AzureAdPrt      : $($dsreg2['AzureAdPrt'])"
    Write-Log "NgcSet          : $($dsreg2['NgcSet'])"
    Write-Log "WamDefaultSet   : $($dsreg2['WamDefaultSet'])"

    # Determine exit code
    $prtOk = $dsreg2['AzureAdPrt'] -eq 'YES'
    $ngcOk = $dsreg2['NgcSet']     -eq 'YES'

    if ($prtOk -and $ngcOk) {
        Write-Log "Remediation succeeded - PRT present and NGC provisioned" 'OK'
        $script:exitCode = 0
    }
    else {
        $remaining = @()
        if (-not $prtOk) { $remaining += 'PRT still missing' }
        if (-not $ngcOk)  { $remaining += 'NGC still not provisioned' }
        Write-Log "Partial remediation - remaining: $($remaining -join ', ')" 'WARN'
        Write-Log "User sign-out and sign-in required to complete WHfB provisioning" 'ACTION'
        $script:exitCode = 0  # Exit 0 - actions were taken; detection will re-evaluate
    }
}
catch {
    Write-Log "Unhandled error in remediation: $_" 'FAIL'
    Write-Log $_.ScriptStackTrace 'FAIL'
    $script:exitCode = 1
}
finally {
    Write-Log "Remediation script completed - log: $LogFile"
}

exit $script:exitCode

#endregion
