# WHfB Intune Proactive Remediation Scripts

Two scripts for use with **Intune Proactive Remediations** to automatically detect and repair broken Windows Hello for Business (WHfB) configurations.

## Scripts

| Script | Purpose |
|--------|---------|
| `Detect-WHfB.ps1` | Detection script — exits 0 (compliant) or 1 (needs remediation) |
| `Remediate-WHfB.ps1` | Remediation script — silently repairs WHfB, runs as SYSTEM |

## What Detect-WHfB.ps1 checks

1. Azure AD / Hybrid join status
2. Primary Refresh Token (PRT) presence
3. NGC key provisioning (NgcSet = YES)
4. TPM health (present, enabled, ready, version)
5. Required services (KeyIso, NgcSvc, NgcCtnrSvc, TokenBroker)
6. WHfB policy registry keys

## What Remediate-WHfB.ps1 does

| Step | Action |
|------|--------|
| 1 | Restart WHfB services |
| 2 | Refresh PRT via scheduled task as logged-on user |
| 3 | Re-trigger Hybrid AAD Join (only if domain-joined but not AAD-joined) |
| 4 | Trigger Intune MDM sync |
| 5 | Clean NGC key store and retrigger provisioning (**only if NgcSet ≠ YES**) |

> **Important:** Step 5 only runs when the NGC key is missing or broken. It will not touch a healthy WHfB key.

## Log output

`C:\ProgramData\WHfB-Repair\WHfB-Remediate_<COMPUTERNAME>_<timestamp>.log`

## Intune deployment

1. Go to **Intune > Devices > Remediations > Create**
2. Upload `Detect-WHfB.ps1` as the detection script
3. Upload `Remediate-WHfB.ps1` as the remediation script
4. Set run context to **SYSTEM**
5. Set schedule to **Every 1 hour** or **Daily**
6. Assign to your Windows 10/11 device group
