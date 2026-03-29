# Dangerous File Detection & Blocklist Reporting

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Detect downloads containing only dangerous files (.exe, .msi, etc.) for TV/Movie labels, blocklist them in Sonarr/Radarr, remove from qBittorrent, and fail the job with clear logging.

**Architecture:** Add a pre-processing safety check in `Invoke-SAStandardJob` (TV/Movie only) that scans the source path for dangerous file extensions. When the download contains ONLY dangerous files (no media), call `DELETE /api/v3/queue/{id}?removeFromClient=true&blocklist=true&skipRedownload=true` using the queue record ID already fetched during early queue lookup. Passthrough jobs are explicitly excluded -- they legitimately process any file type.

**Tech Stack:** PowerShell 5.1+, Sonarr/Radarr v3 API, existing `Invoke-SAWebRequest` HTTP client.

**Scope constraint:** The dangerous file check applies ONLY when `$labelType` is `'tv'` or `'movie'` (i.e., inside `Invoke-SAStandardJob`). Passthrough jobs (`Invoke-SAPassthroughJob`) are untouched -- they handle arbitrary file types by design.

---

### Task 1: Add DangerousExtensions constant

**Files:**
- Modify: `Modules/Stagearr.Core/Private/Constants.ps1:105-113`

**Step 1: Add the constant**

After the existing `VideoExtensionsPattern` entry (line 111), add a new constant inside the `#region File Extensions` block:

```powershell
    # Executable/script extensions that should never appear in media downloads
    # Used by TV/Movie safety check (passthrough jobs are excluded)
    DangerousExtensions = @(
        '.exe', '.msi', '.bat', '.cmd', '.scr', '.com', '.pif',
        '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.lnk'
    )
```

**Step 2: Commit**

```bash
git add Modules/Stagearr.Core/Private/Constants.ps1
git commit -m "feat: add DangerousExtensions constant for malware detection"
```

---

### Task 2: Write tests for Test-SADangerousDownload

**Files:**
- Create: `Tests/DangerousFileDetection.Tests.ps1`

**Step 1: Write the test file**

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Test-SADangerousDownload' {
    BeforeEach {
        # Create a temp directory for each test
        $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "SA-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
    }

    AfterEach {
        if (Test-Path $script:testDir) {
            Remove-Item -Path $script:testDir -Recurse -Force
        }
    }

    It 'returns danger result when folder contains only exe files' {
        InModuleScope 'Stagearr.Core' {
            $dir = $script:testDir
            Set-Content -Path (Join-Path $dir 'Movie.2024.1080p.WEB-DL.exe') -Value 'fake'
            $result = Test-SADangerousDownload -SourcePath $dir
            $result.IsDangerous | Should -Be $true
            $result.DangerousFiles.Count | Should -Be 1
        }
    }

    It 'returns safe result when folder contains media files' {
        InModuleScope 'Stagearr.Core' {
            $dir = $script:testDir
            Set-Content -Path (Join-Path $dir 'Movie.2024.mkv') -Value 'fake'
            $result = Test-SADangerousDownload -SourcePath $dir
            $result.IsDangerous | Should -Be $false
        }
    }

    It 'returns safe result when folder has mixed media and exe files' {
        InModuleScope 'Stagearr.Core' {
            $dir = $script:testDir
            Set-Content -Path (Join-Path $dir 'Movie.2024.mkv') -Value 'fake'
            Set-Content -Path (Join-Path $dir 'setup.exe') -Value 'fake'
            $result = Test-SADangerousDownload -SourcePath $dir
            $result.IsDangerous | Should -Be $false
        }
    }

    It 'detects single dangerous file (not in folder)' {
        InModuleScope 'Stagearr.Core' {
            $filePath = Join-Path $script:testDir 'Episode.S01E01.exe'
            Set-Content -Path $filePath -Value 'fake'
            $result = Test-SADangerousDownload -SourcePath $filePath
            $result.IsDangerous | Should -Be $true
            $result.DangerousFiles.Count | Should -Be 1
        }
    }

    It 'detects multiple dangerous extensions' {
        InModuleScope 'Stagearr.Core' {
            $dir = $script:testDir
            Set-Content -Path (Join-Path $dir 'file.exe') -Value 'fake'
            Set-Content -Path (Join-Path $dir 'file.bat') -Value 'fake'
            Set-Content -Path (Join-Path $dir 'file.scr') -Value 'fake'
            $result = Test-SADangerousDownload -SourcePath $dir
            $result.IsDangerous | Should -Be $true
            $result.DangerousFiles.Count | Should -Be 3
        }
    }

    It 'returns safe when folder is empty' {
        InModuleScope 'Stagearr.Core' {
            $result = Test-SADangerousDownload -SourcePath $script:testDir
            $result.IsDangerous | Should -Be $false
        }
    }

    It 'returns safe when folder has non-media non-dangerous files (nfo, txt)' {
        InModuleScope 'Stagearr.Core' {
            $dir = $script:testDir
            Set-Content -Path (Join-Path $dir 'info.nfo') -Value 'fake'
            Set-Content -Path (Join-Path $dir 'readme.txt') -Value 'fake'
            $result = Test-SADangerousDownload -SourcePath $dir
            $result.IsDangerous | Should -Be $false
        }
    }

    It 'is case-insensitive on extension matching' {
        InModuleScope 'Stagearr.Core' {
            $filePath = Join-Path $script:testDir 'Episode.S01E01.EXE'
            Set-Content -Path $filePath -Value 'fake'
            $result = Test-SADangerousDownload -SourcePath $filePath
            $result.IsDangerous | Should -Be $true
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `pwsh -Command "Invoke-Pester Tests/DangerousFileDetection.Tests.ps1 -Output Detailed"`
Expected: All tests FAIL with "CommandNotFoundException" (function doesn't exist yet).

**Step 3: Commit**

```bash
git add Tests/DangerousFileDetection.Tests.ps1
git commit -m "test: add failing tests for dangerous file detection"
```

---

### Task 3: Implement Test-SADangerousDownload

**Files:**
- Create: `Modules/Stagearr.Core/Private/SafetyCheck.ps1`
- Modify: `Modules/Stagearr.Core/Stagearr.Core.psm1:18-49` (add to PrivateLoadOrder)

**Step 1: Create the implementation**

Create `Modules/Stagearr.Core/Private/SafetyCheck.ps1`:

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Safety checks for downloaded content.
.DESCRIPTION
    Detects dangerous files (executables, scripts) in downloads that should
    only contain media files. Used by TV/Movie processing to catch malware
    disguised as media releases.
#>

function Test-SADangerousDownload {
    <#
    .SYNOPSIS
        Checks if a download contains only dangerous (executable/script) files.
    .DESCRIPTION
        Scans the source path for files with dangerous extensions. Returns dangerous
        ONLY when ALL files in the download are dangerous (no media or other harmless
        files present). A download with mixed content (e.g., .mkv + .exe) is NOT
        flagged -- the normal pipeline will process the media and ignore the rest.
    .PARAMETER SourcePath
        Path to the download (file or folder).
    .OUTPUTS
        PSCustomObject with IsDangerous (bool) and DangerousFiles (array of names).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $safeResult = [PSCustomObject]@{
        IsDangerous    = $false
        DangerousFiles = @()
    }

    $dangerousExts = $script:SAConstants.DangerousExtensions

    # Single file
    if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
        $ext = [System.IO.Path]::GetExtension($SourcePath)
        if ($ext -and ($dangerousExts -contains $ext.ToLower())) {
            return [PSCustomObject]@{
                IsDangerous    = $true
                DangerousFiles = @([System.IO.Path]::GetFileName($SourcePath))
            }
        }
        return $safeResult
    }

    # Folder -- enumerate all files
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        return $safeResult
    }

    $allFiles = @(Get-ChildItem -LiteralPath $SourcePath -File -Recurse -ErrorAction SilentlyContinue)
    if ($allFiles.Count -eq 0) {
        return $safeResult
    }

    $dangerous = @($allFiles | Where-Object {
        $ext = $_.Extension
        $ext -and ($dangerousExts -contains $ext.ToLower())
    })

    if ($dangerous.Count -eq 0) {
        return $safeResult
    }

    # Only flag if ALL files are dangerous (no media or harmless files mixed in)
    $nonDangerous = @($allFiles | Where-Object {
        $ext = $_.Extension
        (-not $ext) -or ($dangerousExts -notcontains $ext.ToLower())
    })

    if ($nonDangerous.Count -gt 0) {
        return $safeResult
    }

    return [PSCustomObject]@{
        IsDangerous    = $true
        DangerousFiles = @($dangerous | ForEach-Object { $_.Name })
    }
}
```

**Step 2: Register in module loader**

In `Modules/Stagearr.Core/Stagearr.Core.psm1`, add `'SafetyCheck.ps1'` to `$PrivateLoadOrder` after `'PathSecurity.ps1'` (line 22):

```
    'PathSecurity.ps1'            # Path validation and security (no dependencies)
    'SafetyCheck.ps1'             # Dangerous file detection for TV/Movie downloads
    'FileIO.ps1'                  # File system I/O utilities (may use PathSecurity)
```

**Step 3: Run tests to verify they pass**

Run: `pwsh -Command "Invoke-Pester Tests/DangerousFileDetection.Tests.ps1 -Output Detailed"`
Expected: All 8 tests PASS.

**Step 4: Commit**

```bash
git add Modules/Stagearr.Core/Private/SafetyCheck.ps1 Modules/Stagearr.Core/Stagearr.Core.psm1
git commit -m "feat: implement Test-SADangerousDownload safety check"
```

---

### Task 4: Write tests for Remove-SAArrQueueItem

**Files:**
- Create: `Tests/ArrQueueRemoval.Tests.ps1`

**Step 1: Write the test file**

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Remove-SAArrQueueItem' {
    It 'calls DELETE with correct URL and parameters' {
        InModuleScope 'Stagearr.Core' {
            $capturedUri = $null
            $capturedMethod = $null
            Mock Invoke-SAWebRequest {
                $capturedUri = $Uri
                $capturedMethod = $Method
                return [PSCustomObject]@{ Success = $true; StatusCode = 200 }
            } -Verifiable

            $config = @{
                host    = 'localhost'
                port    = 8989
                apiKey  = 'testkey123'
                ssl     = $false
                urlRoot = ''
            }

            $result = Remove-SAArrQueueItem -Config $config -QueueId 12345 -Reason 'Dangerous files detected'

            $result.Success | Should -Be $true
            Should -InvokeVerifiable
            Assert-MockCalled Invoke-SAWebRequest -Times 1 -ParameterFilter {
                $Uri -match '/api/v3/queue/12345' -and
                $Uri -match 'removeFromClient=true' -and
                $Uri -match 'blocklist=true' -and
                $Uri -match 'skipRedownload=true' -and
                $Method -eq 'DELETE'
            }
        }
    }

    It 'returns failure when API call fails' {
        InModuleScope 'Stagearr.Core' {
            Mock Invoke-SAWebRequest {
                return [PSCustomObject]@{ Success = $false; ErrorMessage = 'Connection refused' }
            }

            $config = @{
                host    = 'localhost'
                port    = 8989
                apiKey  = 'testkey123'
                ssl     = $false
                urlRoot = ''
            }

            $result = Remove-SAArrQueueItem -Config $config -QueueId 99999 -Reason 'test'

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Be 'Connection refused'
        }
    }
}
```

**Step 2: Run to verify failure**

Run: `pwsh -Command "Invoke-Pester Tests/ArrQueueRemoval.Tests.ps1 -Output Detailed"`
Expected: FAIL with "CommandNotFoundException".

**Step 3: Commit**

```bash
git add Tests/ArrQueueRemoval.Tests.ps1
git commit -m "test: add failing tests for arr queue item removal"
```

---

### Task 5: Implement Remove-SAArrQueueItem

**Files:**
- Modify: `Modules/Stagearr.Core/Private/SafetyCheck.ps1` (append to same file)

**Step 1: Add the function**

Append to `Modules/Stagearr.Core/Private/SafetyCheck.ps1`:

```powershell

function Remove-SAArrQueueItem {
    <#
    .SYNOPSIS
        Removes a queue item from Sonarr/Radarr and optionally blocklists it.
    .DESCRIPTION
        Calls DELETE /api/v3/queue/{id} with removeFromClient=true, blocklist=true,
        and skipRedownload=true. This removes the download from qBittorrent and
        prevents Sonarr/Radarr from re-grabbing the same release.
    .PARAMETER Config
        Importer configuration hashtable (host, port, apiKey, ssl, urlRoot).
    .PARAMETER QueueId
        The queue record ID (from the *arr queue API, NOT the torrent hash).
    .PARAMETER Reason
        Human-readable reason for the removal (logged, not sent to API on v3).
    .OUTPUTS
        PSCustomObject with Success (bool) and ErrorMessage (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [int]$QueueId,

        [Parameter()]
        [string]$Reason = 'Dangerous files detected'
    )

    $urlInfo = Get-SAImporterBaseUrl -Config $Config
    $baseUrl = $urlInfo.Url
    $uri = "$baseUrl/api/v3/queue/${QueueId}?removeFromClient=true&blocklist=true&skipRedownload=true"

    $headers = @{
        'X-Api-Key' = $Config.apiKey
        'Accept'    = 'application/json'
    }
    if ($urlInfo.HostHeader) {
        $headers['Host'] = $urlInfo.HostHeader
    }

    $result = Invoke-SAWebRequest -Uri $uri -Method DELETE -Headers $headers -TimeoutSeconds 15

    if ($result.Success) {
        return [PSCustomObject]@{
            Success      = $true
            ErrorMessage = $null
        }
    }

    return [PSCustomObject]@{
        Success      = $false
        ErrorMessage = $result.ErrorMessage
    }
}
```

**Step 2: Run tests**

Run: `pwsh -Command "Invoke-Pester Tests/ArrQueueRemoval.Tests.ps1 -Output Detailed"`
Expected: All 2 tests PASS.

**Step 3: Commit**

```bash
git add Modules/Stagearr.Core/Private/SafetyCheck.ps1
git commit -m "feat: implement Remove-SAArrQueueItem for blocklist reporting"
```

---

### Task 6: Integrate safety check into Invoke-SAStandardJob

**Files:**
- Modify: `Modules/Stagearr.Core/Public/JobProcessor.ps1:480-596`

This is the core integration. The check goes in `Invoke-SAStandardJob`, AFTER the early queue lookup (so we have queue record IDs) but BEFORE video processing.

**Step 1: Add the safety check block**

In `Invoke-SAStandardJob`, after the *arr queue lookup block (after line 564, before the OMDb query at line 567), insert:

```powershell
    # Safety check: Detect dangerous files in TV/Movie downloads
    # This runs ONLY for TV/Movie labels (passthrough is handled by Invoke-SAPassthroughJob)
    $dangerCheck = Test-SADangerousDownload -SourcePath $Job.input.downloadPath
    if ($dangerCheck.IsDangerous) {
        Write-SAPhaseHeader -Title "Safety Check"
        $fileList = $dangerCheck.DangerousFiles -join ', '
        Write-SAOutcome -Level Error -Label "Security" -Text "Dangerous files detected: $fileList" -Indent 1

        # Attempt to blocklist in *arr and remove from download client
        $blocklisted = $false
        if ($Context.State.EarlyQueueRecords -and $Context.State.EarlyQueueRecords.Count -gt 0) {
            $queueId = $Context.State.EarlyQueueRecords[0].id
            Write-SAVerbose -Text "Blocklisting queue item $queueId in $arrAppType"

            $removeResult = Remove-SAArrQueueItem -Config $arrConfig -QueueId $queueId `
                -Reason "Dangerous files detected: $fileList"

            if ($removeResult.Success) {
                Write-SAOutcome -Level Success -Label "Blocklist" -Text "Removed from $arrAppType and download client" -Indent 1
                $blocklisted = $true
            } else {
                Write-SAOutcome -Level Warning -Label "Blocklist" -Text "Failed: $($removeResult.ErrorMessage)" -Indent 1
            }
        } else {
            Write-SAOutcome -Level Warning -Label "Blocklist" -Text "No queue record available - manual cleanup required" -Indent 1
        }

        # Set up email notification for the failure
        $emailName = $displayName
        Set-SAEmailSummary -Name $emailName `
            -Result 'Failed' `
            -ImportTarget $arrAppType

        $securityMsg = "Dangerous files detected (probable malware): $fileList"
        if ($blocklisted) {
            $securityMsg += " - blocklisted in $arrAppType"
        }
        Add-SAEmailException -Message $securityMsg -Type Error

        # Save log and send notification
        $logPath = Get-SAContextLogPath -Context $Context
        Save-SAFileLog -Path $logPath
        Set-SAEmailLogPath -Path $logPath
        Write-SAProgress -Label "Log" -Text $logPath -Indent 1 -ConsoleOnly

        if (-not $Context.Flags.NoMail -and $Context.Config.notifications.email.enabled) {
            $title = "$($Job.input.downloadLabel) - $displayName"
            $emailBody = ConvertTo-SAEmailHtml -Title $title
            $emailSubject = Get-SAEmailSubject -Result 'Failed'
            Send-SAEmail -Config $Context.Config.notifications.email `
                -Subject $emailSubject `
                -Body $emailBody
        }

        return $false
    }
```

**Step 2: Verify arrAppType and arrConfig are in scope**

The variables `$arrAppType` and `$arrConfig` are set inside the queue lookup `if` block (lines 517-563). The safety check references them. We need to ensure they're initialized outside the `if` so they're always available:

At the top of `Invoke-SAStandardJob` (after `$Context.State.ReleaseInfo = $releaseInfo` at line 501, before the queue lookup block), add:

```powershell
    # Determine *arr app type and config (used by safety check and import)
    $arrAppType = $null
    $arrConfig = $null
```

Then, inside the existing queue lookup block (around line 518), after `$arrAppType` and `$arrConfig` are computed, they're already set. But we also need to set them OUTSIDE the `if` for the safety check to work when the queue lookup is skipped. Add right after the `if` block closes (after line 564):

```powershell
    # Ensure arrAppType/arrConfig are set even if queue lookup was skipped
    if (-not $arrAppType) {
        $arrAppType = if ($labelType -eq 'tv') { 'Sonarr' } else { 'Radarr' }
        $arrConfig = $Context.Config.importers.($arrAppType.ToLower())
    }
```

**Step 3: Commit**

```bash
git add Modules/Stagearr.Core/Public/JobProcessor.ps1
git commit -m "feat: integrate dangerous file safety check into TV/Movie processing

Detects downloads containing only executable/script files (probable
malware). When detected, blocklists the release in Sonarr/Radarr,
removes from qBittorrent, and fails the job with email notification.

Passthrough jobs are unaffected -- they legitimately handle any file type."
```

---

### Task 7: Write integration test for the full flow

**Files:**
- Create: `Tests/DangerousFileIntegration.Tests.ps1`

**Step 1: Write integration test**

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Dangerous file detection integration' {
    It 'Test-SADangerousDownload returns danger for exe-only folder, safe for media folder' {
        InModuleScope 'Stagearr.Core' {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "SA-integ-$([guid]::NewGuid().ToString('N').Substring(0,8))"

            try {
                # Dangerous folder (exe only)
                $dangerDir = Join-Path $tempRoot 'danger'
                New-Item -ItemType Directory -Path $dangerDir -Force | Out-Null
                Set-Content -Path (Join-Path $dangerDir 'Show.S01E01.1080p.WEB-DL.exe') -Value 'malware'

                $result = Test-SADangerousDownload -SourcePath $dangerDir
                $result.IsDangerous | Should -Be $true

                # Safe folder (mkv)
                $safeDir = Join-Path $tempRoot 'safe'
                New-Item -ItemType Directory -Path $safeDir -Force | Out-Null
                Set-Content -Path (Join-Path $safeDir 'Show.S01E01.1080p.WEB-DL.mkv') -Value 'media'

                $result2 = Test-SADangerousDownload -SourcePath $safeDir
                $result2.IsDangerous | Should -Be $false
            }
            finally {
                if (Test-Path $tempRoot) {
                    Remove-Item $tempRoot -Recurse -Force
                }
            }
        }
    }

    It 'DangerousExtensions constant contains expected extensions' {
        InModuleScope 'Stagearr.Core' {
            $exts = $script:SAConstants.DangerousExtensions
            $exts | Should -Contain '.exe'
            $exts | Should -Contain '.msi'
            $exts | Should -Contain '.bat'
            $exts | Should -Contain '.scr'
            $exts | Should -Contain '.lnk'
            $exts | Should -Not -Contain '.mkv'
            $exts | Should -Not -Contain '.mp4'
        }
    }
}
```

**Step 2: Run all tests**

Run: `pwsh -Command "Invoke-Pester Tests/DangerousFile*.Tests.ps1, Tests/ArrQueueRemoval.Tests.ps1 -Output Detailed"`
Expected: All tests PASS.

**Step 3: Commit**

```bash
git add Tests/DangerousFileIntegration.Tests.ps1
git commit -m "test: add integration tests for dangerous file detection"
```

---

### Task 8: Write RCA document

**Files:**
- Create: `Docs/RCA-FAKE-EXE-TORRENTS.md`

**Step 1: Write the RCA**

Document the incident with:
- Date: 2026-03-21
- Provider: IPTorrents (via Prowlarr), RSS feed
- 4 affected releases with IPT torrent IDs
- Root cause: fake torrents uploaded with legitimate group names
- Resolution: Dangerous file detection + blocklist reporting added to Stagearr
- Manual action needed: report the 4 torrents to IPTorrents

**Step 2: Commit**

```bash
git add Docs/RCA-FAKE-EXE-TORRENTS.md
git commit -m "docs: add RCA for fake exe torrent incident (2026-03-21)"
```

---

## File Summary

| Action | File | Purpose |
|--------|------|---------|
| Modify | `Private/Constants.ps1` | Add `DangerousExtensions` list |
| Create | `Private/SafetyCheck.ps1` | `Test-SADangerousDownload` + `Remove-SAArrQueueItem` |
| Modify | `Stagearr.Core.psm1` | Register SafetyCheck.ps1 in load order |
| Modify | `Public/JobProcessor.ps1` | Insert safety check in `Invoke-SAStandardJob` |
| Create | `Tests/DangerousFileDetection.Tests.ps1` | Unit tests for detection logic |
| Create | `Tests/ArrQueueRemoval.Tests.ps1` | Unit tests for queue removal API |
| Create | `Tests/DangerousFileIntegration.Tests.ps1` | Integration tests |
| Create | `Docs/RCA-FAKE-EXE-TORRENTS.md` | Incident documentation |

## What is NOT changed

- `Invoke-SAPassthroughJob` -- untouched, passthrough legitimately handles .exe files
- `Invoke-SAPassthroughProcessing` -- untouched
- `Get-SASourceMediaFiles` / `VideoExtensions` -- unchanged, the safety check is a separate layer
- No new config options -- this is a non-optional safety feature
