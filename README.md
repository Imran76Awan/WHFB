# WHFB — Windows Hello for Business Toolkit

PowerShell scripts and Intune remediations for **deploying, repairing and reporting on Windows Hello for Business (WHfB)** on Hybrid Azure AD / cloud trust devices — plus the blog write-ups behind them.

---

## Repository structure

### 📊 Reporting

| Folder / Script | What it does |
|---|---|
| **[Logon Gesture Report/](Logon%20Gesture%20Report/)** | Reports **which gesture a user actually signed in with** — Face / Fingerprint / PIN / Password — with time and date. Microsoft has no report for this; it's reconstructed from the Windows event logs. |

### 🔧 Intune Proactive Remediations

| Folder | What it does |
|---|---|
| **[Intune Remediation/](Intune%20Remediation/)** | Detect + repair broken WHfB config (join state, PRT, NGC key, TPM health, services, policy keys). |
| **[PRT Remediation/](PRT%20Remediation/)** | Detect + repair a missing/expired **Primary Refresh Token** — the prerequisite for WHfB provisioning. |

### ✅ Detection & status checks

| Script | What it does |
|---|---|
| [`Detect-WHFBEnrollment.ps1`](Detect-WHFBEnrollment.ps1) | Intune detection — exits `0` if `NgcSet = YES`, else `1` (distinguishes "PRT present but not enrolled" from "not registered"). |
| [`Invoke-WHFBEnrollmentCheck.ps1`](Invoke-WHFBEnrollmentCheck.ps1) | Interactive enrollment check run for the logged-on user (prompts to finish WHfB setup until enrolled). |
| [`Register-WHFBScheduledTask.ps1`](Register-WHFBScheduledTask.ps1) | Registers a per-user logon task that runs the enrollment check at each logon until `NgcSet = YES`. |
| [`Check Windows Hello for Business status using registry`](Check%20Windows%20Hello%20for%20Business%20status%20using%20registry) | Registry check of the `PassportForWork` policy (enabled / not enabled). |
| [`Windows Hello for Business Status Check`](Windows%20Hello%20for%20Business%20Status%20Check) | Same check, reporting per user + computer. |
| [`PowerShell Script to Check for PRT`](PowerShell%20Script%20to%20Check%20for%20PRT) | Reports whether a Primary Refresh Token (`AzureAdPrt`) is present. |

### ✍️ Blogs

| Folder | What it does |
|---|---|
| **[Blogs/](Blogs/)** | Long-form write-ups. First post: *Which Windows Hello gesture did they actually use?* — the reverse-engineering story behind the Logon Gesture Report. |

---

## Background

On a hybrid **cloud trust** setup, Windows Hello for Business stores **one** TPM-backed key. PIN, fingerprint and face are three *gestures* that all unlock that same key — so to Entra they're indistinguishable (all reported as "Windows Hello for Business"). These scripts work at the **device** level, where the difference is still visible in the event logs, the registry and `dsregcmd /status`.

> Most scripts read the **Security** event log and therefore need **administrator / SYSTEM** context. The reporting script additionally needs unlock auditing enabled — see its README.
