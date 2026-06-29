<#
  Get-TodayLogons.ps1   (READ-ONLY - run as ADMINISTRATOR)
  Lists every sign-in / unlock with the method (Face / Fingerprint / PIN / Password),
  the time and the date. Default = today; use -Days N to look back further.

  HOW EACH SIGN-IN IS CLASSIFIED (validated on this hardware):
    Fingerprint : Biometrics event 1004 "identified" (names the fingerprint sensor)
    Face        : Biometrics event 1702 "unprotected data" at the unlock, with NO 1004
                  (face on this device does not raise a 1004 'identified' event)
    PIN         : a Hello key-use event (5702/5205) at the unlock, but no biometric
    Password    : an unlock/logon with no biometric and no Hello key event

  REQUIREMENTS:
    - Run as administrator (reads the Security log).
    - Unlock auditing must be ON for PIN/Password UNLOCKS to be recorded:
        auditpol /set /subcategory:"Other Logon/Logoff Events" /success:enable
      (Face/Fingerprint are recorded by the biometric service regardless.)
#>
param([int]$Days = 0)   # 0 = today only

if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  Write-Warning "Run in an ELEVATED PowerShell (Run as administrator) - the logs need admin."; return
}

$sid   = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$start = if($Days -le 0){ (Get-Date).Date } else { (Get-Date).Date.AddDays(-$Days) }

# --- Raw signals ---
$fp = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Biometrics/Operational'; Id=1004; StartTime=$start} -EA SilentlyContinue |
  ForEach-Object { [pscustomobject]@{ Time=$_.TimeCreated; Sensor=(($_.Message -replace '.*using sensor: ') -split '\(')[0].Trim() } }
$faceAuth = (Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Biometrics/Operational'; Id=1702; StartTime=$start} -EA SilentlyContinue).TimeCreated
$hello    = (Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-HelloForBusiness/Operational'; Id=5205,5702; StartTime=$start} -EA SilentlyContinue).TimeCreated

# anchors = real unlock/logon moments (Security log)
$anchors = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624,4801; StartTime=$start} -EA SilentlyContinue |
  ForEach-Object { $id=$_.Id; $x=[xml]$_.ToXml(); $d=@{}; $x.Event.EventData.Data | % { $d[$_.Name]=$_.'#text' }
    $keep = if($id -eq 4801){ $d.TargetUserSid -eq $sid } else { $d.TargetUserSid -eq $sid -and $d.LogonType -in '2','11' }
    if($keep){ [pscustomobject]@{ Time=$_.TimeCreated; Kind= if($id -eq 4801){'Unlock'}else{'Logon'} } } }

function Near($t,$set,$sec){ @($set | Where-Object { [math]::Abs(($t - $_).TotalSeconds) -le $sec }).Count -gt 0 }

$events = @()
# 1) classify every audited unlock/logon
foreach($a in $anchors){
  $t=$a.Time
  $fpHit = $fp | Where-Object { [math]::Abs(($t - $_.Time).TotalSeconds) -le 8 } | Select-Object -First 1
  $method = if($fpHit){ if($fpHit.Sensor -match 'fingerprint|MOC'){'Fingerprint'}elseif($fpHit.Sensor -match 'Face|Facial'){'Face'}else{'Biometric'} }
            elseif(Near $t $faceAuth 5){ 'Face' }
            elseif(Near $t $hello 8){ 'PIN' }
            else { 'Password' }
  $events += [pscustomobject]@{ Time=$t; Method=$method; Source="$($a.Kind) (Security log)" }
}
# 2) add biometric sign-ins NOT covered by an audited anchor (e.g. unlocks before auditing was on)
foreach($f in $fp){
  if(-not (Near $f.Time $anchors.Time 30)){
    $m = if($f.Sensor -match 'fingerprint|MOC'){'Fingerprint'}elseif($f.Sensor -match 'Face|Facial'){'Face'}else{'Biometric'}
    $events += [pscustomobject]@{ Time=$f.Time; Method=$m; Source='Biometric (sign-in/unlock)' }
  }
}

if(-not $events){ Write-Host "No sign-in events found since $($start.ToString('yyyy-MM-dd'))."; return }
$label = if($Days -le 0){'TODAY'}else{"last $Days days"}
Write-Host "`n=== Sign-ins ($label) on $env:COMPUTERNAME ===`n"
$events | Sort-Object Time |
  Select-Object @{n='Date';e={$_.Time.ToString('yyyy-MM-dd')}}, @{n='Time';e={$_.Time.ToString('HH:mm:ss')}}, Method, Source |
  Format-Table -AutoSize
