# PRT Intune Proactive Remediation Scripts

Two scripts for use with **Intune Proactive Remediations** to automatically detect and repair a missing or broken Primary Refresh Token (PRT) on Hybrid AAD / Azure AD Joined devices.

The PRT is a prerequisite for Windows Hello for Business. A device with no PRT will fail WHfB provisioning even if it is correctly joined and the TPM is healthy.

## Scripts

| Script | Purpose |
|--------|---------|
| `Detect-PRT.ps1` | Detection script — exits 0 (compliant) or 1 (needs remediation) |
| `Remediate-PRT.ps1` | Remediation script — 6-step staged PRT recovery, runs as logged-on user |

## What Detect-PRT.ps1 checks

| Check | What it evaluates |
|-------|------------------|
| 1 | AzureAdJoined = YES |
| 2 | DomainJoined = YES |
| 3 | AzureAdPrt = YES (PRT present) |
| 4 | PRT not expired and not expiring within 4 hours |

## What Remediate-PRT.ps1 does

| Step | Action | Stops if |
|------|--------|----------|
| 1 | Restart TokenBroker service | — |
| 2 | `dsregcmd /refreshprt` | PRT obtained |
| 3 | Trigger Automatic-Device-Join scheduled task + refresh | PRT obtained |
| 4 | Clear WAM token cache (registry) + re-run /refreshprt | PRT obtained |
| 5 | `dsregcmd /debug /refreshprt` (verbose) | PRT obtained |
| 6 | `dsregcmd /forcerecovery` + re-trigger join + refresh | PRT obtained |
| 7 | Diagnostic snapshot with root cause identification | Always exits 1 |

> **Note:** Step 6 (`/forcerecovery`) is aggressive — it resets device registration state. It only runs when all previous steps have failed.

## Log output

`%LOCALAPPDATA%\PRT-Repair\PRT-Remediate_<COMPUTERNAME>_<timestamp>.log`

## Colour scheme

| Colour | Meaning |
|--------|---------|
| Green | OK / PASS — step succeeded |
| Cyan | ACTION — step is running |
| Yellow | WARN — step skipped or non-fatal issue |
| Red | FAIL — step failed or PRT not recovered |
| Gray | INFO — general output |

## Intune deployment

1. Go to **Intune > Devices > Remediations > Create**
2. Upload `Detect-PRT.ps1` as the detection script
3. Upload `Remediate-PRT.ps1` as the remediation script
4. **Run using logged-on credentials: Yes** — both scripts require user context
5. Run script in 64-bit PowerShell: Yes
6. Set schedule to **Every 1 hour** or **Daily**
7. Assign to your Windows 10/11 Hybrid AAD Joined device group

## Related

See also: [WHfB Intune Proactive Remediation](../Intune%20Remediation/) — fixes broken NGC keys once the PRT is healthy.
