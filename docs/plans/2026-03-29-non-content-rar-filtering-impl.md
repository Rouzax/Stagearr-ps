# Non-Content RAR Filtering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Skip proof/sample/nfo RARs during detection so standalone video files are processed instead.

**Architecture:** Add a `Test-SANonContentRar` filter function (like existing `Test-SASamplePath`), centralize patterns in Constants, apply filter at both RAR detection points (Context.ps1, Staging.ps1).

**Tech Stack:** PowerShell 5.1+, Pester 5 tests

---

### Task 1: Add NonContentRarPatterns to Constants

**Files:**
- Modify: `Modules/Stagearr.Core/Private/Constants.ps1:118-120` (after DangerousExtensions, before `#endregion`)

**Step 1: Add the constant**

Insert after the `DangerousExtensions` closing paren (line 118), before `#endregion` (line 120):

```powershell
    # RAR filename patterns for non-content archives (proof images, samples, nfo)
    # Case-insensitive match against filename without extension
    NonContentRarPatterns = @('proof', 'sample', 'nfo')
```

**Step 2: Verify module loads**

Run: `pwsh -c "Import-Module ./Modules/Stagearr.Core/Stagearr.Core.psd1 -Force; Write-Host 'OK'"`
Expected: `OK`

**Step 3: Commit**

```bash
git add Modules/Stagearr.Core/Private/Constants.ps1
git commit -m "feat: add NonContentRarPatterns constant for proof/sample/nfo RAR filtering"
```

---

### Task 2: Add Test-SANonContentRar function

**Files:**
- Modify: `Modules/Stagearr.Core/Private/PathSecurity.ps1` (append after `Test-SASamplePath`, after line 157)

**Step 1: Write the test file**

Create `Tests/NonContentRar.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Test-SANonContentRar' {
    It 'detects proof RAR: <Name>' -ForEach @(
        @{ Name = 'tm-theruleofjenny-2160p-hevc-proof.rar'; Expected = $true }
        @{ Name = 'group-proof.rar'; Expected = $true }
        @{ Name = 'PROOF.rar'; Expected = $true }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ Name = $Name; Expected = $Expected } {
            Test-SANonContentRar -Name $Name | Should -Be $Expected
        }
    }

    It 'detects sample RAR: <Name>' -ForEach @(
        @{ Name = 'movie-sample.rar'; Expected = $true }
        @{ Name = 'Sample.rar'; Expected = $true }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ Name = $Name; Expected = $Expected } {
            Test-SANonContentRar -Name $Name | Should -Be $Expected
        }
    }

    It 'detects nfo RAR: <Name>' -ForEach @(
        @{ Name = 'group-nfo.rar'; Expected = $true }
        @{ Name = 'release.nfo.rar'; Expected = $true }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ Name = $Name; Expected = $Expected } {
            Test-SANonContentRar -Name $Name | Should -Be $Expected
        }
    }

    It 'allows content RAR: <Name>' -ForEach @(
        @{ Name = 'tm-theruleofjenny-2160p-hevc.rar'; Expected = $false }
        @{ Name = 'movie.part01.rar'; Expected = $false }
        @{ Name = 'release-group.rar'; Expected = $false }
    ) {
        InModuleScope 'Stagearr.Core' -Parameters @{ Name = $Name; Expected = $Expected } {
            Test-SANonContentRar -Name $Name | Should -Be $Expected
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `pwsh -c "Invoke-Pester ./Tests/NonContentRar.Tests.ps1 -Output Detailed"`
Expected: FAIL -- `Test-SANonContentRar` not found

**Step 3: Implement Test-SANonContentRar**

Append to `Modules/Stagearr.Core/Private/PathSecurity.ps1` after line 157:

```powershell

function Test-SANonContentRar {
    <#
    .SYNOPSIS
        Tests if a RAR filename matches non-content patterns (proof, sample, nfo).
    .DESCRIPTION
        Scene releases often include small RAR archives containing proof images,
        sample clips, or NFO files alongside the main video content. These should
        not trigger RAR extraction mode.
    .PARAMETER Name
        The RAR filename to test.
    .EXAMPLE
        Test-SANonContentRar -Name "tm-movie-proof.rar"
        # Returns: $true
    .EXAMPLE
        Test-SANonContentRar -Name "tm-movie-2160p.rar"
        # Returns: $false
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    foreach ($pattern in $script:SAConstants.NonContentRarPatterns) {
        if ($baseName -match "(?i)(^|[-._])$pattern([-._]|$)") {
            return $true
        }
    }

    return $false
}
```

The regex `(?i)(^|[-._])pattern([-._]|$)` matches the keyword as a distinct segment separated by common scene delimiters (`-`, `.`, `_`) or at start/end. This avoids false positives like "proofread" while catching "group-proof", "proof.rar", "movie-sample", etc.

**Step 4: Run tests to verify they pass**

Run: `pwsh -c "Invoke-Pester ./Tests/NonContentRar.Tests.ps1 -Output Detailed"`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Modules/Stagearr.Core/Private/PathSecurity.ps1 Tests/NonContentRar.Tests.ps1
git commit -m "feat: add Test-SANonContentRar to detect proof/sample/nfo archives"
```

---

### Task 3: Filter non-content RARs in Context.ps1

**Files:**
- Modify: `Modules/Stagearr.Core/Private/Context.ps1:156-160`

**Step 1: Add test cases to NonContentRar.Tests.ps1**

Append a new `Describe` block to `Tests/NonContentRar.Tests.ps1`:

```powershell

Describe 'Context IsRarArchive detection' {
    BeforeEach {
        InModuleScope 'Stagearr.Core' {
            $script:testDir = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-test-$(New-Guid)"
            New-Item -Path $script:testDir -ItemType Directory -Force | Out-Null
        }
    }

    AfterEach {
        InModuleScope 'Stagearr.Core' {
            if (Test-Path $script:testDir) {
                Remove-Item -Path $script:testDir -Recurse -Force
            }
        }
    }

    It 'sets IsRarArchive false when folder has only proof RAR and a video file' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'movie.mkv') -Value 'video'
            Set-Content -Path (Join-Path $script:testDir 'group-proof.rar') -Value 'proof'

            $job = @{ input = @{ downloadPath = $script:testDir }; label = 'Movie' }
            $config = @{ processing = @{ stagingRoot = (Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-staging-$(New-Guid)") } }
            $context = Initialize-SAContext -Job $job -Config $config
            $context.State.IsRarArchive | Should -BeFalse
        }
    }

    It 'sets IsRarArchive true when folder has content RAR and proof RAR' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'movie.rar') -Value 'content'
            Set-Content -Path (Join-Path $script:testDir 'group-proof.rar') -Value 'proof'

            $job = @{ input = @{ downloadPath = $script:testDir }; label = 'Movie' }
            $config = @{ processing = @{ stagingRoot = (Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-staging-$(New-Guid)") } }
            $context = Initialize-SAContext -Job $job -Config $config
            $context.State.IsRarArchive | Should -BeTrue
        }
    }

    It 'sets IsRarArchive true when folder has only content RAR' {
        InModuleScope 'Stagearr.Core' {
            Set-Content -Path (Join-Path $script:testDir 'movie.rar') -Value 'content'

            $job = @{ input = @{ downloadPath = $script:testDir }; label = 'Movie' }
            $config = @{ processing = @{ stagingRoot = (Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-staging-$(New-Guid)") } }
            $context = Initialize-SAContext -Job $job -Config $config
            $context.State.IsRarArchive | Should -BeTrue
        }
    }
}
```

**Step 2: Run tests to verify the new context tests fail**

Run: `pwsh -c "Invoke-Pester ./Tests/NonContentRar.Tests.ps1 -Output Detailed"`
Expected: First context test FAILS (proof RAR currently sets IsRarArchive true)

**Step 3: Update Context.ps1**

Replace `Modules/Stagearr.Core/Private/Context.ps1` lines 156-160:

```powershell
        # Check for RAR files in folder
        $rarFiles = Get-ChildItem -LiteralPath $sourcePath -Filter '*.rar' -Recurse -ErrorAction SilentlyContinue
        if ($rarFiles.Count -gt 0) {
            $Context.State.IsRarArchive = $true
        }
```

With:

```powershell
        # Check for content RAR files in folder (skip proof/sample/nfo archives)
        $rarFiles = @(Get-ChildItem -LiteralPath $sourcePath -Filter '*.rar' -Recurse -ErrorAction SilentlyContinue)
        $contentRars = @($rarFiles | Where-Object { -not (Test-SANonContentRar -Name $_.Name) })
        $skippedRars = @($rarFiles | Where-Object { Test-SANonContentRar -Name $_.Name })
        foreach ($skipped in $skippedRars) {
            Write-SAVerbose -Text "Skipped non-content RAR: $($skipped.Name)"
        }
        if ($contentRars.Count -gt 0) {
            $Context.State.IsRarArchive = $true
        }
```

**Step 4: Run tests to verify they pass**

Run: `pwsh -c "Invoke-Pester ./Tests/NonContentRar.Tests.ps1 -Output Detailed"`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Modules/Stagearr.Core/Private/Context.ps1 Tests/NonContentRar.Tests.ps1
git commit -m "fix: skip proof/sample/nfo RARs when detecting IsRarArchive in context"
```

---

### Task 4: Filter non-content RARs in Staging.ps1 (defense-in-depth)

**Files:**
- Modify: `Modules/Stagearr.Core/Public/Staging.ps1:212-216`

**Step 1: Update Staging.ps1**

Replace `Modules/Stagearr.Core/Public/Staging.ps1` lines 212-216:

```powershell
            $rarFiles = Get-ChildItem -LiteralPath $sourcePath -Filter '*.rar' -Recurse |
                Where-Object { $_.Name -notmatch '\.part(?!01)\d+\.rar$' } |
                Sort-Object Name |
                Select-Object -First 1
            $rarFile = $rarFiles
```

With:

```powershell
            $rarFiles = Get-ChildItem -LiteralPath $sourcePath -Filter '*.rar' -Recurse |
                Where-Object { $_.Name -notmatch '\.part(?!01)\d+\.rar$' } |
                Where-Object { -not (Test-SANonContentRar -Name $_.Name) } |
                Sort-Object Name |
                Select-Object -First 1
            $rarFile = $rarFiles
```

**Step 2: Run all tests**

Run: `pwsh -c "Invoke-Pester ./Tests/NonContentRar.Tests.ps1 -Output Detailed"`
Expected: All tests PASS

**Step 3: Run full test suite for regressions**

Run: `pwsh -c "Invoke-Pester ./Tests/ -Output Detailed"`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add Modules/Stagearr.Core/Public/Staging.ps1
git commit -m "fix: filter non-content RARs from main RAR selection in staging"
```
