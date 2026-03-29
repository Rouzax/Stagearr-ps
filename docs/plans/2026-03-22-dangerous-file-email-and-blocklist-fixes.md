# Dangerous File Detection: Email & Blocklist Fixes

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix two bugs in the dangerous file detection feature: (1) blocklist API call fails due to byte[] response body in PS Core, (2) failure emails are not descriptive -- they show generic "Failed" with no phase/error/suggestions.

**Architecture:** Bug 1 is a PS Core compatibility issue in Http.ps1 where `$response.Content` returns `byte[]` instead of `string`. Bug 2 requires populating `FailurePhase`, `FailureError`, and `FailurePath` in the email summary for dangerous file detections, adding a "Security" phase to the troubleshooting suggestions, and changing the email subject prefix from "Failed" to "Blocked" for security events.

**Tech Stack:** PowerShell 5.1/7.x, Pester tests

---

## Bug Analysis

### Bug 1: Blocklist API `RawContent` type error

**Root cause:** In `Http.ps1:278`, `$responseContent = $response.Content` returns a `byte[]` in PowerShell Core for responses without a text Content-Type. Sonarr's DELETE `/api/v3/queue/{id}` returns an empty or non-text response. When `$responseContent` (a `byte[]`) is passed to `New-SAHttpResult -RawContent $responseContent` at line 297, it fails because `-RawContent` is typed as `[string]`.

**Effect chain:**
1. First attempt: DELETE succeeds (200/204), but `New-SAHttpResult` throws on `[string]$RawContent` receiving `byte[]`
2. Exception caught by generic `catch` block (line 380), logged as retry
3. Second attempt: DELETE returns 404 (item already deleted by first attempt)
4. Third attempt: Same 404, max retries exceeded, returns failure
5. Log shows: `"Blocklist: Failed: Response status code does not indicate success: 404 (Not Found)."`

So the blocklist actually works (item gets deleted on first attempt), but the success is swallowed by the type error.

### Bug 2: Email not descriptive for dangerous file detections

**Root cause:** In `JobProcessor.ps1:604-606`, `Set-SAEmailSummary` is called with only `-Name`, `-Result 'Failed'`, and `-ImportTarget`. The `-FailurePhase`, `-FailureError`, and `-FailurePath` parameters are NOT set.

**Effect:**
- Email subject: `"Failed: TV: The Pitt S02E12 1080p WEB h264-ETHEL.exe"` -- no indication it was a security issue
- "What Happened" card: Shows "Phase: Processing" and "Error: An error occurred" (defaults)
- "What to Check" card: Shows generic suggestions instead of security-specific guidance
- Status badge: Shows generic "FAILED" instead of something security-specific

---

## Task 1: Fix Http.ps1 byte[] to string conversion

**Files:**
- Modify: `Modules/Stagearr.Core/Private/Http.ps1:278` (response content assignment)
- Test: `Tests/HttpByteArray.Tests.ps1` (new -- targeted test)

**Step 1: Write failing test**

Create `Tests/HttpByteArray.Tests.ps1`:

```powershell
#Requires -Version 5.1
Describe 'New-SAHttpResult RawContent handling' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'Stagearr.Core' 'Stagearr.Core.psm1'
        Import-Module $modulePath -Force
    }

    It 'accepts a string for RawContent' {
        $result = New-SAHttpResult -Success $true -RawContent 'hello'
        $result.RawContent | Should -Be 'hello'
    }

    It 'accepts $null for RawContent' {
        $result = New-SAHttpResult -Success $true -RawContent $null
        $result.RawContent | Should -BeNullOrEmpty
    }

    It 'accepts empty string for RawContent' {
        $result = New-SAHttpResult -Success $true -RawContent ''
        $result.RawContent | Should -Be ''
    }
}
```

**Step 2: Run test to verify it passes (baseline)**

Run: `pwsh -Command "Invoke-Pester Tests/HttpByteArray.Tests.ps1 -PassThru"`
Expected: All 3 pass (these are baseline -- the bug is in `Invoke-SAWebRequest`, not `New-SAHttpResult` itself)

**Step 3: Fix response content coercion in Http.ps1**

In `Modules/Stagearr.Core/Private/Http.ps1`, change line 278 from:

```powershell
$responseContent = $response.Content
```

to:

```powershell
# PS Core can return byte[] for Content on non-text responses (e.g., empty DELETE responses).
# Coerce to string for consistent downstream handling.
$responseContent = if ($response.Content -is [byte[]]) {
    if ($response.Content.Length -gt 0) {
        [System.Text.Encoding]::UTF8.GetString($response.Content)
    } else {
        ''
    }
} else {
    $response.Content
}
```

**Step 4: Run existing tests**

Run: `pwsh -Command "Invoke-Pester Tests/ -PassThru"` and confirm no regressions.

**Step 5: Commit**

```
fix(http): coerce byte[] response content to string for PS Core compatibility

Sonarr DELETE /api/v3/queue returns empty body that PS Core represents
as byte[], causing New-SAHttpResult to fail on [string]$RawContent.
The blocklist actually succeeded but the error swallowed the success
and retries got 404.
```

---

## Task 2: Populate email failure details for dangerous file detections

**Files:**
- Modify: `Modules/Stagearr.Core/Public/JobProcessor.ps1:604-606` (Set-SAEmailSummary call)

**Step 1: Update Set-SAEmailSummary call for dangerous files**

In `Modules/Stagearr.Core/Public/JobProcessor.ps1`, change lines 603-606 from:

```powershell
        # Set up email notification for the failure
        Set-SAEmailSummary -Name $displayName `
            -Result 'Failed' `
            -ImportTarget $arrAppType
```

to:

```powershell
        # Set up email notification for the security block
        Set-SAEmailSummary -Name $displayName `
            -Result 'Failed' `
            -ImportTarget $arrAppType `
            -FailurePhase 'Security' `
            -FailureError "Dangerous files detected (probable malware): $fileList" `
            -FailurePath $Job.input.downloadPath
```

**Step 2: Run existing tests**

Run: `pwsh -Command "Invoke-Pester Tests/ -PassThru"` and confirm no regressions.

**Step 3: Commit**

```
fix(email): populate failure details for dangerous file detections

The "What Happened" card now shows phase "Security", the actual error
message with file names, and the source path instead of generic defaults.
```

---

## Task 3: Add security-specific troubleshooting suggestions

**Files:**
- Modify: `Modules/Stagearr.Core/Private/Output/EmailSections.ps1:950` (switch block in `Get-SAEmailTroubleshootingSuggestions`)

**Step 1: Write failing test**

Create or add to an existing test file. Add `Tests/EmailSecuritySuggestions.Tests.ps1`:

```powershell
#Requires -Version 5.1
Describe 'Get-SAEmailTroubleshootingSuggestions for Security phase' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'Stagearr.Core' 'Stagearr.Core.psm1'
        Import-Module $modulePath -Force
    }

    It 'returns security-specific suggestions for Security phase' {
        $summary = @{
            FailurePhase = 'Security'
            FailureError = 'Dangerous files detected (probable malware): show.exe'
            ImportTarget = 'Sonarr'
        }
        $suggestions = Get-SAEmailTroubleshootingSuggestions -Summary $summary
        $suggestions.Count | Should -BeGreaterOrEqual 2
        $suggestions[0] | Should -BeLike '*malware*'
    }
}
```

**Step 2: Run test to verify it fails**

Run: `pwsh -Command "Invoke-Pester Tests/EmailSecuritySuggestions.Tests.ps1 -PassThru"`
Expected: FAIL -- the Security phase falls through to the `default` case and returns generic suggestions.

**Step 3: Add Security case to troubleshooting switch**

In `Modules/Stagearr.Core/Private/Output/EmailSections.ps1`, add a new case in the `switch -Regex ($phase)` block (before the `default` case around line 1040):

```powershell
        'Security' {
            $suggestions += 'This release contained only executable/script files (probable malware)'
            $suggestions += 'The torrent has been blocklisted to prevent re-download'
            $suggestions += 'Report the fake release to your indexer'
        }
```

**Step 4: Run test to verify it passes**

Run: `pwsh -Command "Invoke-Pester Tests/EmailSecuritySuggestions.Tests.ps1 -PassThru"`
Expected: PASS

**Step 5: Commit**

```
feat(email): add security-specific troubleshooting suggestions

When a dangerous file detection triggers, the "What to Check" card now
shows relevant guidance instead of generic "check the log" suggestions.
```

---

## Task 4: Change email subject prefix from "Failed" to "Blocked" for security events

**Files:**
- Modify: `Modules/Stagearr.Core/Private/Output/EmailSubject.ps1:295,390` (add 'Blocked' to ValidateSet)
- Modify: `Modules/Stagearr.Core/Private/Output/EmailSubject.ps1:306-309` (add 'Blocked' prefix)
- Modify: `Modules/Stagearr.Core/Private/Output/EmailRenderer.ps1:201` (add 'Blocked' to ValidateSet)
- Modify: `Modules/Stagearr.Core/Private/Output/EmailSections.ps1:143,159,684` (add 'Blocked' to ValidateSet + styling)
- Modify: `Modules/Stagearr.Core/Public/JobProcessor.ps1:605,623` (use 'Blocked' result for dangerous files)

**Step 1: Write failing test**

Add `Tests/EmailBlockedSubject.Tests.ps1`:

```powershell
#Requires -Version 5.1
Describe 'Email subject with Blocked result' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'Stagearr.Core' 'Stagearr.Core.psm1'
        Import-Module $modulePath -Force
    }

    It 'generates Blocked prefix for Blocked result' {
        $placeholders = Build-SASubjectPlaceholders -Name 'Show S01E01' -Label 'TV' -Result 'Blocked'
        $placeholders.result | Should -Be 'Blocked: '
    }

    It 'produces correct subject with Blocked result' {
        $placeholders = Build-SASubjectPlaceholders -Name 'Show S01E01' -Label 'TV' -Result 'Blocked'
        $subject = Format-SAEmailSubject -Template 'none' -Placeholders $placeholders
        $subject | Should -Be 'Blocked: TV: Show S01E01'
    }
}
```

**Step 2: Run test to verify it fails**

Run: `pwsh -Command "Invoke-Pester Tests/EmailBlockedSubject.Tests.ps1 -PassThru"`
Expected: FAIL -- 'Blocked' not in ValidateSet

**Step 3: Add 'Blocked' to all ValidateSet attributes and styling**

Add `'Blocked'` to every `ValidateSet('Success', 'Warning', 'Failed', 'Skipped')` in these files:

1. **EmailSubject.ps1** -- lines 295 and 390: change to `[ValidateSet('Success', 'Warning', 'Failed', 'Skipped', 'Blocked')]`
2. **EmailSubject.ps1** -- line 306-309: add case:
   ```powershell
   'Blocked' { 'Blocked: ' }
   ```
3. **EmailRenderer.ps1** -- line 201: change to `[ValidateSet('Success', 'Warning', 'Failed', 'Skipped', 'Blocked')]`
4. **EmailSections.ps1** -- line 143: change to `[ValidateSet('Success', 'Warning', 'Failed', 'Skipped', 'Blocked')]`
5. **EmailSections.ps1** -- line 156-160: add badge config:
   ```powershell
   'Blocked' { @{ Color = $colors.FailedRed; Icon = $xmark; Text = 'BLOCKED' } }
   ```
6. **EmailSections.ps1** -- line 87: add `'Blocked'` to the condition so it uses the failure layout:
   ```powershell
   if ($Summary.Result -eq 'Failed' -or $Summary.Result -eq 'Blocked') {
   ```
7. **EmailSections.ps1** -- line 684: change to `[ValidateSet('Success', 'Warning', 'Failed', 'Skipped', 'Blocked')]`
8. **EmailSections.ps1** -- lines 691-693 and 698-700: add `'Blocked'` case mapping to `$colors.FailedRed`

**Step 4: Update JobProcessor to use 'Blocked' result**

In `Modules/Stagearr.Core/Public/JobProcessor.ps1`, change the dangerous file email setup (line 605):

```powershell
            -Result 'Blocked' `
```

And line 623 (`Get-SAEmailSubject` call):

```powershell
            $emailSubject = Get-SAEmailSubject -Result 'Blocked'
```

**Step 5: Run tests to verify they pass**

Run: `pwsh -Command "Invoke-Pester Tests/ -PassThru"`
Expected: All pass including the new `EmailBlockedSubject.Tests.ps1`

**Step 6: Commit**

```
feat(email): use "Blocked" subject prefix for dangerous file detections

Email subject now reads "Blocked: TV: Show S01E01" instead of "Failed: TV: ..."
making it immediately clear this was a security block, not a processing failure.
Status badge shows "BLOCKED" in red.
```

---

## Task 5: Manual verification with log replay

**Step 1: Review all changes holistically**

Read through the modified files end-to-end to ensure consistency:
- Http.ps1 byte[] fix
- JobProcessor.ps1 email summary changes
- EmailSections.ps1 troubleshooting + ValidateSet changes
- EmailSubject.ps1 Blocked result prefix

**Step 2: Run full test suite**

Run: `pwsh -Command "Invoke-Pester Tests/ -PassThru"`
Expected: All pass, no regressions.

**Step 3: Commit (if any final adjustments needed)**

---

## Expected Results After Fix

### Email subject
Before: `Failed: TV: The Pitt S02E12 1080p WEB h264-ETHEL.exe`
After: `Blocked: TV: The Pitt S02E12 [1080p WEB-ETHEL]`

### Email "What Happened" card
Before: Phase = "Processing", Error = "An error occurred"
After: Phase = "Security", Error = "Dangerous files detected (probable malware): The Pitt S02E12 1080p WEB h264-ETHEL.exe", Path = source download path

### Email "What to Check" card
Before: Generic "Check the log file" / "Verify all configuration settings"
After: "This release contained only executable/script files (probable malware)" / "The torrent has been blocklisted to prevent re-download" / "Report the fake release to your indexer"

### Blocklist behavior
Before: Silently succeeds, then logs failure due to 404 on retry
After: Succeeds and reports success correctly
