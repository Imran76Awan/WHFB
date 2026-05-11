<#
.SYNOPSIS
    Checks device PRT and Windows Hello for Business enrollment status.
    Prompts unregistered users to enroll and opens the WHfB PIN setup UI.

.DESCRIPTION
    Reads dsregcmd /status output to determine:
      - Whether the device has a valid Azure AD Primary Refresh Token (PRT)
      - Whether Windows Hello for Business (NgcSet) is already provisioned

    If a PRT exists but NgcSet is NO, a GUI prompt is shown offering to open
    Windows Sign-in Options so the user can create their WHfB PIN.
    Okta FastPass MFA will be triggered automatically by the enrollment wizard.

.NOTES
    Deploy via Intune (Platform Scripts) or as a scheduled task at logon.
    Run as the logged-on user (NOT SYSTEM) so dsregcmd returns user-context data.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    # Suppress the GUI and just return exit codes (useful for Intune detection rules)
    [switch]$Silent,

    # Path for transcript log; defaults to %TEMP%\WHFBCheck.log
    [string]$LogPath = "$env:TEMP\WHFBCheck.log"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $ts  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

# ---------------------------------------------------------------------------
# Parse dsregcmd /status
# ---------------------------------------------------------------------------
function Get-DsRegStatus {
    $raw    = & dsregcmd /status 2>&1
    $status = [ordered]@{}
    foreach ($line in $raw) {
        if ($line -match '^\s+([\w]+)\s*:\s*(\S+)') {
            $status[$Matches[1]] = $Matches[2]
        }
    }
    return $status
}

# ---------------------------------------------------------------------------
# GUI prompt
# ---------------------------------------------------------------------------
function Show-EnrollPrompt {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    $form                  = New-Object System.Windows.Forms.Form
    $form.Text             = 'Windows Hello for Business - Enrollment Required'
    $form.Size             = New-Object System.Drawing.Size(520, 310)
    $form.StartPosition    = 'CenterScreen'
    $form.FormBorderStyle  = 'FixedDialog'
    $form.MaximizeBox      = $false
    $form.MinimizeBox      = $false
    $form.TopMost          = $true
    $form.BackColor        = [System.Drawing.Color]::White

    # Blue banner strip
    $banner            = New-Object System.Windows.Forms.Panel
    $banner.Dock       = 'Top'
    $banner.Height     = 55
    $banner.BackColor  = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $form.Controls.Add($banner)

    $bannerLabel           = New-Object System.Windows.Forms.Label
    $bannerLabel.Text      = '  Windows Hello for Business Setup Required'
    $bannerLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $bannerLabel.ForeColor = [System.Drawing.Color]::White
    $bannerLabel.Dock      = 'Fill'
    $bannerLabel.TextAlign = 'MiddleLeft'
    $banner.Controls.Add($bannerLabel)

    # Body text
    $body          = New-Object System.Windows.Forms.Label
    $body.Text     = @"
Your device has a valid Primary Refresh Token (PRT) and is registered
with Azure AD, but Windows Hello for Business has not been set up yet.

Clicking Enroll Now will:
  1. Open Windows Sign-in Options
  2. Guide you through creating your PIN
  3. Trigger Okta FastPass MFA to complete enrollment
"@
    $body.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
    $body.Location = New-Object System.Drawing.Point(20, 70)
    $body.Size     = New-Object System.Drawing.Size(480, 145)
    $form.Controls.Add($body)

    # Enroll button
    $btnEnroll              = New-Object System.Windows.Forms.Button
    $btnEnroll.Text         = 'Enroll Now'
    $btnEnroll.Font         = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnEnroll.Location     = New-Object System.Drawing.Point(290, 235)
    $btnEnroll.Size         = New-Object System.Drawing.Size(110, 38)
    $btnEnroll.BackColor    = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnEnroll.ForeColor    = [System.Drawing.Color]::White
    $btnEnroll.FlatStyle    = 'Flat'
    $btnEnroll.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnEnroll)

    # Later button
    $btnLater              = New-Object System.Windows.Forms.Button
    $btnLater.Text         = 'Remind me later'
    $btnLater.Font         = New-Object System.Drawing.Font('Segoe UI', 9)
    $btnLater.Location     = New-Object System.Drawing.Point(410, 235)
    $btnLater.Size         = New-Object System.Drawing.Size(88, 38)
    $btnLater.FlatStyle    = 'Flat'
    $btnLater.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnLater)

    $form.AcceptButton = $btnEnroll
    $form.CancelButton = $btnLater

    return $form.ShowDialog()
}

# ---------------------------------------------------------------------------
# Win32 mouse-click helper (loaded once; safe to call multiple times)
# Used because Windows 11 Settings (WinUI 3) does not support
# ExpandCollapsePattern or InvokePattern on accordion/button elements.
# ---------------------------------------------------------------------------
function Initialize-MouseHelper {
    if (-not ([System.Management.Automation.PSTypeName]'WinClick').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinClick {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(150);
        mouse_event(0x0002, x, y, 0, UIntPtr.Zero);  // MOUSEEVENTF_LEFTDOWN
        System.Threading.Thread.Sleep(80);
        mouse_event(0x0004, x, y, 0, UIntPtr.Zero);  // MOUSEEVENTF_LEFTUP
    }
}
'@
    }
}

# ---------------------------------------------------------------------------
# Click a UI Automation element — tries InvokePattern first,
# then falls back to a real Win32 mouse click at the element's screen coords.
# ---------------------------------------------------------------------------
function Invoke-UIElement {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [string]$ElementName
    )

    # --- Try InvokePattern ---
    try {
        $pat = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $pat.Invoke()
        Write-Log "'$ElementName' clicked via InvokePattern."
        return $true
    } catch {
        Write-Log "InvokePattern unsupported for '$ElementName', trying mouse click..." 'WARN'
    }

    # --- Fallback: Win32 mouse click at element centre ---
    try {
        $rect = $Element.Current.BoundingRectangle
        if ($rect.Width -gt 0 -and $rect.Height -gt 0) {
            $cx = [int]($rect.X + $rect.Width  / 2)
            $cy = [int]($rect.Y + $rect.Height / 2)
            [WinClick]::Click($cx, $cy)
            Write-Log "'$ElementName' clicked via Win32 mouse at ($cx, $cy)."
            return $true
        } else {
            Write-Log "BoundingRectangle for '$ElementName' is zero-sized; cannot mouse-click." 'WARN'
        }
    } catch {
        Write-Log "Win32 mouse click failed for '$ElementName': $_" 'WARN'
    }

    return $false
}

# ---------------------------------------------------------------------------
# Launch WHfB PIN enrollment UI and auto-expand the PIN section
# ---------------------------------------------------------------------------
function Start-WHFBEnrollment {
    Write-Log "Opening Windows Sign-in Options..."

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
    Initialize-MouseHelper

    # Open Settings > Accounts > Sign-in options
    Start-Process 'ms-settings:signinoptions'

    # ------------------------------------------------------------------
    # Wait for the Settings window (up to 20 s)
    # ------------------------------------------------------------------
    $nameProp    = [System.Windows.Automation.AutomationElement]::NameProperty
    $root        = [System.Windows.Automation.AutomationElement]::RootElement
    $settingsWin = $null

    Write-Log "Waiting for Settings window..."
    for ($i = 0; $i -lt 20; $i++) {
        $cond        = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Settings')
        $settingsWin = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
        if ($settingsWin) { break }
        Start-Sleep -Seconds 1
    }

    if (-not $settingsWin) {
        Write-Log "Settings window not found. Showing manual instructions." 'WARN'
        Show-FallbackInstructions
        return
    }

    try { $settingsWin.SetFocus() } catch {}
    Start-Sleep -Milliseconds 800

    # ------------------------------------------------------------------
    # Step 1 — Expand the "PIN (Windows Hello)" accordion row
    # Strategy order:  ExpandCollapsePattern  >  InvokePattern  >  mouse click
    # NOTE: Windows 11 Settings (WinUI 3) usually only responds to mouse click
    # ------------------------------------------------------------------
    $pinExpanded = $false
    try {
        Write-Log "Searching for 'PIN (Windows Hello)' element..."
        $pinCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'PIN (Windows Hello)')
        $pinItem = $settingsWin.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $pinCond)

        if ($pinItem) {
            # Check if already expanded (Set up button already visible)
            $alreadyOpen = $false
            try {
                $expandPat  = $pinItem.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                $alreadyOpen = ($expandPat.Current.ExpandCollapseState -eq
                               [System.Windows.Automation.ExpandCollapseState]::Expanded)
                if ($alreadyOpen) {
                    Write-Log "PIN section already expanded."
                    $pinExpanded = $true
                } else {
                    $expandPat.Expand()
                    Write-Log "PIN section expanded via ExpandCollapsePattern."
                    $pinExpanded = $true
                }
            } catch {
                # ExpandCollapsePattern not supported (expected on Win11) — use mouse click
                Write-Log "ExpandCollapsePattern unsupported; using mouse click to expand PIN section."
                $pinExpanded = Invoke-UIElement -Element $pinItem -ElementName 'PIN (Windows Hello)'
            }
        } else {
            Write-Log "'PIN (Windows Hello)' element not found in Settings UI." 'WARN'
        }
    } catch {
        Write-Log "Error locating PIN section: $_" 'WARN'
    }

    # Allow the accordion animation to complete
    Start-Sleep -Milliseconds 800

    # ------------------------------------------------------------------
    # Step 2 — Find and AUTO-CLICK the "Set up" button
    # Always attempted regardless of whether Step 1 succeeded, because
    # the Settings URI may have already rendered the section open.
    # ------------------------------------------------------------------
    $setupClicked = $false
    try {
        Write-Log "Searching for 'Set up' button..."
        $setupCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Set up')

        # Retry up to 5 s in case the accordion animation is still running
        $setupBtn = $null
        for ($i = 0; $i -lt 5; $i++) {
            $setupBtn = $settingsWin.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $setupCond)
            if ($setupBtn) { break }
            Start-Sleep -Seconds 1
        }

        if ($setupBtn) {
            # Scroll it into view so it is fully visible on screen before clicking
            try {
                $scrollPat = $setupBtn.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern)
                $scrollPat.ScrollIntoView()
                Start-Sleep -Milliseconds 400
            } catch {}

            try { $setupBtn.SetFocus() } catch {}
            Start-Sleep -Milliseconds 200

            $setupClicked = Invoke-UIElement -Element $setupBtn -ElementName 'Set up'

            if ($setupClicked) {
                Write-Log "Set up button clicked. Okta MFA wizard should now appear."
            }
        } else {
            Write-Log "'Set up' button not found in Settings window." 'WARN'
        }
    } catch {
        Write-Log "Error while clicking Set up button: $_" 'WARN'
    }

    # Give Okta MFA window time to appear before showing the overlay
    if ($setupClicked) { Start-Sleep -Seconds 1 }

    Show-PinSetupTip -PinExpanded $pinExpanded -SetupClicked $setupClicked
}

# ---------------------------------------------------------------------------
# Helper: contextual tip after automation completes
# ---------------------------------------------------------------------------
function Show-PinSetupTip {
    param(
        [bool]$PinExpanded,
        [bool]$SetupClicked
    )

    if ($SetupClicked) {
        # Best case: Set up was auto-clicked, Okta MFA is now on screen
        [System.Windows.Forms.MessageBox]::Show(
            "The Windows Hello PIN setup wizard has been launched for you.`n`n" +
            "An Okta verification window is now open (it may be behind this message).`n`n" +
            "To finish enrollment:`n" +
            "  1. Click OK below, then switch to the Okta window`n" +
            "  2. Select 'Use Okta FastPass' or another MFA method`n" +
            "  3. Approve the request in Okta Verify`n" +
            "  4. Create and confirm your new Windows Hello PIN`n`n" +
            "Your device will be fully enrolled once the PIN is saved.",
            'WHfB PIN Setup - Complete Okta MFA',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

    } elseif ($PinExpanded) {
        # PIN section is open but Set up could not be auto-clicked
        [System.Windows.Forms.MessageBox]::Show(
            "Windows Sign-in Options is open and the PIN section is expanded.`n`n" +
            "One manual step needed:`n" +
            "  1. Click the 'Set up' button in the Settings window`n" +
            "  2. Complete Okta FastPass MFA when prompted`n" +
            "  3. Create and confirm your new PIN`n`n" +
            "Your device will be fully enrolled once the PIN is saved.",
            'WHfB PIN Setup - One Step Remaining',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

    } else {
        # Neither automation step worked — fully manual
        Show-FallbackInstructions
    }
}

# ---------------------------------------------------------------------------
# Helper: fallback if Settings window was not automatable
# ---------------------------------------------------------------------------
function Show-FallbackInstructions {
    [System.Windows.Forms.MessageBox]::Show(
        "Settings > Accounts > Sign-in Options is open.`n`n" +
        "Please follow these steps:`n" +
        "  1. Click 'PIN (Windows Hello)' to expand it`n" +
        "  2. Click the 'Set up' button`n" +
        "  3. Complete Okta FastPass MFA when prompted`n" +
        "  4. Create and confirm your PIN",
        'WHfB PIN Setup - Manual Steps',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== WHfB Enrollment Check started for $env:USERNAME on $env:COMPUTERNAME ==="

$status = Get-DsRegStatus

$aadJoined     = $status['AzureAdJoined']    -eq 'YES'
$workplaceJoin = $status['WorkplaceJoined']  -eq 'YES'
$hasPRT        = $status['AzureAdPrt']       -eq 'YES'
$ngcSet        = $status['NgcSet']           -eq 'YES'

Write-Log "AzureAdJoined   : $($status['AzureAdJoined'])"
Write-Log "WorkplaceJoined : $($status['WorkplaceJoined'])"
Write-Log "AzureAdPrt      : $($status['AzureAdPrt'])"
Write-Log "NgcSet          : $($status['NgcSet'])"

# --- Guard: device must be joined/registered before WHfB makes sense ---
if (-not ($aadJoined -or $workplaceJoin)) {
    Write-Log "Device is not Azure AD joined or workplace registered. Skipping WHfB check." 'WARN'
    exit 2
}

# --- Guard: PRT must exist ---
if (-not $hasPRT) {
    Write-Log "No valid PRT found. User may not be signed in to Azure AD. Skipping." 'WARN'
    exit 3
}

# --- Already enrolled ---
if ($ngcSet) {
    Write-Log "NgcSet = YES - Windows Hello for Business is already enrolled. Nothing to do."
    exit 0
}

# --- PRT present, WHfB missing: prompt user ---
Write-Log "PRT present but NgcSet = NO. Prompting user to enroll." 'WARN'

if ($Silent) {
    Write-Log "Silent mode - skipping GUI. Exiting with code 1 (enrollment required)." 'WARN'
    exit 1
}

$choice = Show-EnrollPrompt

if ($choice -eq [System.Windows.Forms.DialogResult]::OK) {
    Write-Log "User chose to enroll. Launching WHfB PIN setup."
    Start-WHFBEnrollment
    exit 0
} else {
    Write-Log "User deferred enrollment." 'WARN'
    exit 1
}
