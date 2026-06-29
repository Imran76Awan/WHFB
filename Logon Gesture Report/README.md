# Logon Gesture Report

Find out **which Windows Hello gesture a user actually signed in with** — Face, Fingerprint, PIN or Password — with the exact time and date.

Microsoft has **no report** for this. Entra sign-in logs only show *"Windows Hello for Business"* vs *"Password"* — face, fingerprint and PIN all collapse into one label, because all three unlock the **same** TPM-backed key. The only place the gesture is distinguishable is **locally, in the Windows event logs**.

## `Get-TodayLogons.ps1`

Read-only. Lists every sign-in / unlock today (or last *N* days with `-Days N`) classified by method.

```powershell
# Run in an ELEVATED PowerShell (Run as administrator)
powershell -ExecutionPolicy Bypass -File ".\Get-TodayLogons.ps1"
powershell -ExecutionPolicy Bypass -File ".\Get-TodayLogons.ps1" -Days 7
```

### How it classifies each sign-in

| Method | Signal at the moment of sign-in |
|---|---|
| **Fingerprint** | `Microsoft-Windows-Biometrics/Operational` event **1004** "identified" (names the fingerprint sensor) |
| **Face** | Biometrics event **1702** "unprotected data" **with no 1004** |
| **PIN** | `Microsoft-Windows-HelloForBusiness/Operational` event **5702/5205** (Hello key used), but no biometric |
| **Password** | An unlock/logon (`4624`/`4801`) with **neither** biometric **nor** Hello key |

Anchor events come from the **Security** log: `4624` (logon) and `4801` (workstation unlock).

### Requirements

- Run as **Administrator** — the Security log is admin-only (it's the only place password sign-ins are recorded).
- **Unlock auditing must be ON** for PIN/Password *unlocks* to be captured:
  ```cmd
  auditpol /set /subcategory:"Other Logon/Logoff Events" /success:enable
  ```
  Face and Fingerprint are logged by the Biometric service regardless of audit policy.

### Notes

- Face/Fingerprint counts are **exact**. PIN/Password require the audit setting above; history *before* it was enabled will undercount them.
- The PIN-vs-Password split relies on a **tight** time window (a few seconds) between the unlock and the Hello-key event — the Hello key fires constantly in the background, so a loose window misclassifies everything as PIN.

## Full write-up

See the blog post: **[../Blogs/windows-hello-which-gesture-did-they-use.html](../Blogs/windows-hello-which-gesture-did-they-use.html)** — the complete reverse-engineering story, with the event IDs, the audit-policy gotcha, and the face-vs-PIN discovery.

## Coming next

- Part 2: this classifier as an **Intune remediation (detection) script** running as SYSTEM, fleet-wide audit policy, and a **web app pulling live data via the Microsoft Graph API**.
