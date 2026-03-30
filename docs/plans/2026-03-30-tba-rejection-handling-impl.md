# TBA Rejection Handling Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Handle Sonarr TBA rejections by refreshing metadata inline, improve all rejection category mappings, and make email messages clearly attribute the source importer.

**Architecture:** Expand the existing rejection simplification/error-type/hint pipeline with new categories. Add a TBA-specific retry flow in `Invoke-SAArrImport` Step 5 that calls Sonarr's RefreshSeries API, waits, and re-scans. Prefix all import email exceptions with the importer label.

**Tech Stack:** PowerShell 5.1+/7.x, Pester 5, Sonarr API v3

**Design doc:** `docs/plans/2026-03-30-tba-rejection-handling-design.md`

---

### Task 1: Add New Rejection Category Mappings

**Files:**
- Modify: `Modules/Stagearr.Core/Private/ArrMetadata.ps1:376-442` (`Get-SASimplifiedRejectionReason`)
- Test: `Tests/RejectionMappings.Tests.ps1`

**Step 1: Write failing tests**

Create `Tests/RejectionMappings.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Get-SASimplifiedRejectionReason' {

    Context 'existing mappings still work' {
        It 'maps quality rejection' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Not an upgrade for existing episode file(s)' | Should -Be 'Quality exists'
            }
        }

        It 'maps sample rejection' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Sample' | Should -Be 'Sample file'
            }
        }

        It 'maps parse failure' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Unknown Series' | Should -Be 'Cannot parse'
            }
        }

        It 'maps already imported' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Episode file already imported at 2026-03-30' | Should -Be 'Already imported'
            }
        }

        It 'maps file locked' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Locked file, try again later' | Should -Be 'File locked'
            }
        }
    }

    Context 'TBA title rejections' {
        It 'maps TBA title' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Episode has a TBA title and recently aired' | Should -Be 'Episode title TBA'
            }
        }

        It 'maps missing title' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Episode does not have a title and recently aired' | Should -Be 'Episode title TBA'
            }
        }
    }

    Context 'disk space rejection' {
        It 'maps free space' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Not enough free space' | Should -Be 'Not enough disk space'
            }
        }
    }

    Context 'scene mapping rejection' {
        It 'maps unverified scene mapping' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'This show has individual episode mappings on TheXEM but the mapping for this episode has not been confirmed yet' | Should -Be 'Unverified scene mapping'
            }
        }
    }

    Context 'no audio rejection' {
        It 'maps no audio tracks' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'No audio tracks detected' | Should -Be 'No audio tracks'
            }
        }
    }

    Context 'season rejections' {
        It 'maps full season' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Single episode file contains all episodes in seasons' | Should -Be 'Full season file'
            }
        }

        It 'maps partial season' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Partial season packs are not supported' | Should -Be 'Partial season pack'
            }
        }
    }

    Context 'absolute episode number rejection' {
        It 'maps missing absolute number' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Episode does not have an absolute episode number and recently aired' | Should -Be 'Missing absolute episode number'
            }
        }
    }

    Context 'episode mismatch rejections' {
        It 'maps unexpected episode' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Episode 5 was unexpected considering the S01E04 folder name' | Should -Be 'Unexpected episode'
            }
        }

        It 'maps existing file has more episodes' {
            InModuleScope 'Stagearr.Core' {
                Get-SASimplifiedRejectionReason -Reason 'Episode file on disk contains more episodes than this file contains' | Should -Be 'Existing file has more episodes'
            }
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `pwsh -Command "Invoke-Pester Tests/RejectionMappings.Tests.ps1 -Output Detailed"`
Expected: New category tests FAIL (TBA, disk space, scene mapping, etc.), existing tests PASS.

**Step 3: Implement new mappings**

In `Modules/Stagearr.Core/Private/ArrMetadata.ps1`, expand `Get-SASimplifiedRejectionReason`. Insert the new patterns **before** the existing ones (order matters - more specific patterns first):

```powershell
    # TBA / missing title rejections
    if ($lower -match 'tba title|does not have a title') {
        return 'Episode title TBA'
    }

    # Missing absolute episode number (anime)
    if ($lower -match 'absolute episode number') {
        return 'Missing absolute episode number'
    }

    # Disk space
    if ($lower -match 'free space|not enough space') {
        return 'Not enough disk space'
    }

    # Scene mapping
    if ($lower -match 'unverified.*scene|xem|scene.*mapping') {
        return 'Unverified scene mapping'
    }

    # No audio tracks
    if ($lower -match 'no audio') {
        return 'No audio tracks'
    }

    # Full season
    if ($lower -match 'full season|all episodes in season') {
        return 'Full season file'
    }

    # Partial season
    if ($lower -match 'partial season') {
        return 'Partial season pack'
    }

    # Episode mismatch
    if ($lower -match 'unexpected.*considering') {
        return 'Unexpected episode'
    }

    # Existing file has more episodes
    if ($lower -match 'more episodes') {
        return 'Existing file has more episodes'
    }
```

Insert these before the existing `# Quality/upgrade rejections` block (line 406). The `'free space'` pattern must come before the existing patterns since `$script:ArrErrorPatterns` in ImportResultParser.ps1 also has a space pattern, but these are independent functions.

**Step 4: Run tests to verify they pass**

Run: `pwsh -Command "Invoke-Pester Tests/RejectionMappings.Tests.ps1 -Output Detailed"`
Expected: ALL tests PASS.

**Step 5: Commit**

```bash
git add Tests/RejectionMappings.Tests.ps1 Modules/Stagearr.Core/Private/ArrMetadata.ps1
git commit -m "feat: add comprehensive rejection category mappings for Sonarr/Radarr"
```

---

### Task 2: Add New Error Types and Hints

**Files:**
- Modify: `Modules/Stagearr.Core/Public/ImportArr.ps1:475-483` (`Get-SAErrorTypeFromRejection`)
- Modify: `Modules/Stagearr.Core/Private/ImportResultParser.ps1:874-911` (`Get-SAImportHint`)
- Test: `Tests/RejectionMappings.Tests.ps1` (extend)

**Step 1: Add error type and hint tests**

Append to `Tests/RejectionMappings.Tests.ps1`:

```powershell
Describe 'Get-SAErrorTypeFromRejection' {

    It 'maps Episode title TBA to tba' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Episode title TBA' | Should -Be 'tba'
        }
    }

    It 'maps Missing absolute episode number to tba' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Missing absolute episode number' | Should -Be 'tba'
        }
    }

    It 'maps Not enough disk space to disk-space' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Not enough disk space' | Should -Be 'disk-space'
        }
    }

    It 'maps Unverified scene mapping to scene-mapping' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Unverified scene mapping' | Should -Be 'scene-mapping'
        }
    }

    It 'maps No audio tracks to corrupt-file' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'No audio tracks' | Should -Be 'corrupt-file'
        }
    }

    It 'maps Full season file to full-season' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Full season file' | Should -Be 'full-season'
        }
    }

    It 'maps Partial season pack to partial-season' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Partial season pack' | Should -Be 'partial-season'
        }
    }

    It 'maps Unexpected episode to episode-mismatch' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Unexpected episode' | Should -Be 'episode-mismatch'
        }
    }

    It 'maps Existing file has more episodes to episode-mismatch' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Existing file has more episodes' | Should -Be 'episode-mismatch'
        }
    }

    # Existing mappings still work
    It 'maps Quality exists to quality' {
        InModuleScope 'Stagearr.Core' {
            Get-SAErrorTypeFromRejection -PrimaryReason 'Quality exists' | Should -Be 'quality'
        }
    }
}

Describe 'Get-SAImportHint' {

    It 'returns TBA hint for Sonarr' {
        InModuleScope 'Stagearr.Core' {
            $hint = Get-SAImportHint -ErrorType 'tba' -ImporterLabel 'Sonarr'
            $hint | Should -BeLike '*48 hours*'
            $hint | Should -BeLike '*-Rerun*'
        }
    }

    It 'returns disk space hint' {
        InModuleScope 'Stagearr.Core' {
            $hint = Get-SAImportHint -ErrorType 'disk-space' -ImporterLabel 'Sonarr'
            $hint | Should -BeLike '*space*'
        }
    }

    It 'returns scene mapping hint' {
        InModuleScope 'Stagearr.Core' {
            $hint = Get-SAImportHint -ErrorType 'scene-mapping' -ImporterLabel 'Sonarr'
            $hint | Should -BeLike '*TheXEM*'
        }
    }

    It 'returns corrupt file hint' {
        InModuleScope 'Stagearr.Core' {
            $hint = Get-SAImportHint -ErrorType 'corrupt-file' -ImporterLabel 'Sonarr'
            $hint | Should -BeLike '*corrupt*'
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `pwsh -Command "Invoke-Pester Tests/RejectionMappings.Tests.ps1 -Output Detailed"`
Expected: New error type + hint tests FAIL.

**Step 3: Add error types to `Get-SAErrorTypeFromRejection`**

In `Modules/Stagearr.Core/Public/ImportArr.ps1`, expand the switch block in `Get-SAErrorTypeFromRejection` (after line 478):

```powershell
        'episode title tba|missing absolute'  { return 'tba' }
        'not enough disk'   { return 'disk-space' }
        'scene mapping'     { return 'scene-mapping' }
        'no audio'          { return 'corrupt-file' }
        'full season'       { return 'full-season' }
        'partial season'    { return 'partial-season' }
        'unexpected episode|more episodes' { return 'episode-mismatch' }
```

**Step 4: Add hints to `Get-SAImportHint`**

In `Modules/Stagearr.Core/Private/ImportResultParser.ps1`, add cases before the `'unknown'` case (line 902):

```powershell
        'tba' {
            return "$ImporterLabel auto-accepts TBA titles after 48 hours. Use -Rerun to retry."
        }
        'disk-space' {
            return "Free up space on the destination drive or adjust minimum free space in $ImporterLabel settings"
        }
        'scene-mapping' {
            return "Episode mapping on TheXEM is unverified; wait for confirmation or use Manual Import in $ImporterLabel"
        }
        'corrupt-file' {
            return "File may be corrupt or incomplete; re-download or check source"
        }
        'full-season' {
            return "Use Manual Import in $ImporterLabel to import full season files"
        }
        'partial-season' {
            return "Partial season packs are not supported; import individual episodes"
        }
        'episode-mismatch' {
            return "File contains unexpected episodes; use Manual Import in $ImporterLabel to verify"
        }
```

**Step 5: Run tests to verify they pass**

Run: `pwsh -Command "Invoke-Pester Tests/RejectionMappings.Tests.ps1 -Output Detailed"`
Expected: ALL tests PASS.

**Step 6: Commit**

```bash
git add Tests/RejectionMappings.Tests.ps1 Modules/Stagearr.Core/Public/ImportArr.ps1 Modules/Stagearr.Core/Private/ImportResultParser.ps1
git commit -m "feat: add error types and hints for all rejection categories"
```

---

### Task 3: Email Clarity - Prefix Importer Label

**Files:**
- Modify: `Modules/Stagearr.Core/Public/ImportArr.ps1` (all `Add-SAEmailException` calls in `Invoke-SAArrImport`)
- Test: `Tests/RejectionMappings.Tests.ps1` (extend)

**Step 1: Write failing test**

Append to `Tests/RejectionMappings.Tests.ps1`:

```powershell
Describe 'Invoke-SAArrImport email exception label prefix' {

    It 'prefixes rejection warning with Sonarr label' {
        InModuleScope 'Stagearr.Core' {
            Mock Write-SAVerbose {}
            Mock Write-SAProgress {}
            Mock Write-SAOutcome {}
            Mock Write-SAPhaseHeader {}
            Mock Get-SAImportHint { return $null }

            Mock Get-SAImporterBaseUrl {
                return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
            }

            Mock Test-SAArrConnection { return $true }

            Mock Invoke-SAArrManualImportScan {
                return [PSCustomObject]@{
                    Success      = $true
                    ScanResults  = @(
                        @{
                            path       = 'C:\Test\S01E01.mkv'
                            quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                            series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                            episodes   = @( @{ id = 200 } )
                            rejections = @( @{ type = 'permanent'; reason = 'Not an upgrade for existing episode file(s)' } )
                        }
                    )
                    ErrorMessage = $null
                }
            }

            Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
            Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }

            $capturedMessages = @()
            Mock Add-SAEmailException {
                $script:capturedMessages += $Message
            }

            $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
            $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test'

            $script:capturedMessages | Should -Contain 'Sonarr: 1 file skipped (Quality exists)'
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run: `pwsh -Command "Invoke-Pester Tests/RejectionMappings.Tests.ps1 -Output Detailed -Filter 'email exception label'"`
Expected: FAIL - message is `"1 file skipped (Quality exists)"` without `"Sonarr: "` prefix.

**Step 3: Prefix all `Add-SAEmailException` calls in `Invoke-SAArrImport`**

In `Modules/Stagearr.Core/Public/ImportArr.ps1`, update these 5 lines in `Invoke-SAArrImport`:

Line 186:
```powershell
        Add-SAEmailException -Message "$label: Scan failed: $($scanResult.ErrorMessage)" -Type Error
```

Line 200:
```powershell
        Add-SAEmailException -Message "$label: No files found in folder" -Type Warning
```

Line 278:
```powershell
        Add-SAEmailException -Message "$label`: $($rejectionSummary.Message)" -Type Warning
```

Line 308:
```powershell
        Add-SAEmailException -Message "$label`: $($rejectionSummary.Message)" -Type Warning
```

Line 434:
```powershell
        Add-SAEmailException -Message "$label`: $($importResult.Message)" -Type Error
```

Note: Use backtick-colon (`` $label`: ``) or `"$label: "` string form to avoid PowerShell parsing issues.

**Step 4: Run test to verify it passes**

Run: `pwsh -Command "Invoke-Pester Tests/RejectionMappings.Tests.ps1 -Output Detailed"`
Expected: ALL tests PASS.

**Step 5: Check existing tests still pass**

Run: `pwsh -Command "Invoke-Pester Tests/ImportArrPartialImport.Tests.ps1 Tests/ImportArrDownloadId.Tests.ps1 -Output Detailed"`
Expected: If any tests check exact email exception messages, they may need updating to include the label prefix. Fix as needed.

**Step 6: Commit**

```bash
git add Modules/Stagearr.Core/Public/ImportArr.ps1 Tests/RejectionMappings.Tests.ps1
git commit -m "feat: prefix email exception messages with importer label"
```

---

### Task 4: Add TBA Refresh Constant and SeriesRefresh Function

**Files:**
- Modify: `Modules/Stagearr.Core/Private/Constants.ps1`
- Modify: `Modules/Stagearr.Core/Public/ImportArr.ps1` (add `Invoke-SAArrSeriesRefresh`)
- Test: `Tests/TbaRefresh.Tests.ps1`

**Step 1: Write failing test**

Create `Tests/TbaRefresh.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Invoke-SAArrSeriesRefresh' {

    Context 'successful refresh' {
        It 'sends RefreshSeries command and returns success' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Invoke-SAImporterCommand {
                    return [PSCustomObject]@{
                        Success   = $true
                        CommandId = 12345
                        Status    = 'queued'
                        Message   = $null
                    }
                }

                Mock Wait-SAImporterCommand {
                    return [PSCustomObject]@{
                        Success  = $true
                        Message  = 'Completed'
                        Duration = 10
                        Status   = 'completed'
                        Result   = 'successful'
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrSeriesRefresh -Config $config -SeriesId 100

                $result.Success | Should -BeTrue

                # Verify RefreshSeries command was sent with correct body
                Should -Invoke Invoke-SAImporterCommand -Times 1 -ParameterFilter {
                    $Body.name -eq 'RefreshSeries' -and $Body.seriesId -eq 100
                }

                # Verify polling used the TBA timeout
                Should -Invoke Wait-SAImporterCommand -Times 1 -ParameterFilter {
                    $CommandId -eq 12345 -and $TimeoutMinutes -eq $script:SAConstants.TbaRefreshTimeoutMinutes
                }
            }
        }
    }

    Context 'command send failure' {
        It 'returns failure without polling' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Invoke-SAImporterCommand {
                    return [PSCustomObject]@{
                        Success   = $false
                        CommandId = $null
                        Status    = $null
                        Message   = 'API error'
                    }
                }

                Mock Wait-SAImporterCommand {}

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = '' }
                $result = Invoke-SAArrSeriesRefresh -Config $config -SeriesId 100

                $result.Success | Should -BeFalse
                Should -Invoke Wait-SAImporterCommand -Times 0
            }
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `pwsh -Command "Invoke-Pester Tests/TbaRefresh.Tests.ps1 -Output Detailed"`
Expected: FAIL - `Invoke-SAArrSeriesRefresh` not found.

**Step 3: Add constant**

In `Modules/Stagearr.Core/Private/Constants.ps1`, add inside the `#region Import Defaults` section (after line 40):

```powershell
    # How long to wait for series metadata refresh before giving up (minutes)
    TbaRefreshTimeoutMinutes = 2
```

**Step 4: Implement `Invoke-SAArrSeriesRefresh`**

In `Modules/Stagearr.Core/Public/ImportArr.ps1`, add after the `#endregion` of the ManualImport Execute section (after line 981, before `#region Radarr Backward-Compatibility Wrappers`):

```powershell
#region Series Metadata Refresh

function Invoke-SAArrSeriesRefresh {
    <#
    .SYNOPSIS
        Refreshes series metadata in Sonarr to resolve TBA episode titles.
    .DESCRIPTION
        Sends a RefreshSeries command to Sonarr and waits for completion.
        Used when ManualImport scan rejects files due to TBA episode titles.
        Sonarr will re-fetch episode metadata from TVDB/TMDB.
    .PARAMETER Config
        Sonarr configuration hashtable (host, port, apiKey, etc.).
    .PARAMETER SeriesId
        The Sonarr series ID to refresh.
    .OUTPUTS
        PSCustomObject with Success (bool) and Message (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [int]$SeriesId
    )

    $commandBody = @{
        name     = 'RefreshSeries'
        seriesId = $SeriesId
    }

    Write-SAVerbose -Text "Sending RefreshSeries command (seriesId: $SeriesId)"

    $commandResult = Invoke-SAImporterCommand -Config $Config -Body $commandBody

    if (-not $commandResult.Success) {
        Write-SAVerbose -Text "RefreshSeries command failed: $($commandResult.Message)"
        return [PSCustomObject]@{
            Success = $false
            Message = $commandResult.Message
        }
    }

    Write-SAVerbose -Text "RefreshSeries command ID: $($commandResult.CommandId)"

    $timeout = $script:SAConstants.TbaRefreshTimeoutMinutes
    $pollResult = Wait-SAImporterCommand -Config $Config -CommandId $commandResult.CommandId -TimeoutMinutes $timeout

    return [PSCustomObject]@{
        Success = $pollResult.Success
        Message = $pollResult.Message
    }
}

#endregion
```

**Step 5: Run tests to verify they pass**

Run: `pwsh -Command "Invoke-Pester Tests/TbaRefresh.Tests.ps1 -Output Detailed"`
Expected: ALL tests PASS.

**Step 6: Commit**

```bash
git add Modules/Stagearr.Core/Private/Constants.ps1 Modules/Stagearr.Core/Public/ImportArr.ps1 Tests/TbaRefresh.Tests.ps1
git commit -m "feat: add Invoke-SAArrSeriesRefresh for TBA metadata refresh"
```

---

### Task 5: TBA Detection and Refresh+Retry in Import Flow

**Files:**
- Modify: `Modules/Stagearr.Core/Public/ImportArr.ps1:270-303` (Step 5 in `Invoke-SAArrImport`)
- Test: `Tests/TbaRefresh.Tests.ps1` (extend)

**Step 1: Write failing test for TBA refresh+retry flow**

Append to `Tests/TbaRefresh.Tests.ps1`:

```powershell
Describe 'Invoke-SAArrImport TBA refresh and retry' {

    Context 'TBA rejection triggers refresh and re-scan succeeds' {
        It 'should refresh metadata and import successfully' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Write-SAPhaseHeader {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Test-SAArrConnection { return $true }
                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
                Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }
                Mock Add-SAEmailException {}
                Mock Get-SAImportHint { return $null }

                # First scan: TBA rejection. Second scan: importable.
                $scanCallCount = 0
                Mock Invoke-SAArrManualImportScan {
                    $script:scanCallCount++
                    if ($script:scanCallCount -eq 1) {
                        return [PSCustomObject]@{
                            Success      = $true
                            ScanResults  = @(
                                @{
                                    path       = 'C:\Test\S01E01.mkv'
                                    quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                    series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                    episodes   = @( @{ id = 200 } )
                                    rejections = @( @{ type = 'permanent'; reason = 'Episode has a TBA title and recently aired' } )
                                }
                            )
                            ErrorMessage = $null
                        }
                    } else {
                        return [PSCustomObject]@{
                            Success      = $true
                            ScanResults  = @(
                                @{
                                    path       = 'C:\Test\S01E01.mkv'
                                    quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                    series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                    episodes   = @( @{ id = 200 } )
                                    languages  = @( @{ id = 1; name = 'English' } )
                                    rejections = @()
                                }
                            )
                            ErrorMessage = $null
                        }
                    }
                }

                Mock Invoke-SAArrSeriesRefresh {
                    return [PSCustomObject]@{ Success = $true; Message = 'Completed' }
                }

                Mock Invoke-SAArrManualImportExecute {
                    return [PSCustomObject]@{
                        Success   = $true
                        Message   = 'Completed'
                        Duration  = 5
                        CommandId = 99999
                        Status    = 'completed'
                        Result    = 'successful'
                    }
                }

                Mock Get-SAImportVerification {
                    return [PSCustomObject]@{
                        ImportedCount = 1
                        ExpectedCount = 1
                        IsComplete    = $true
                        Records       = @()
                    }
                }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test'

                $result.Success | Should -BeTrue
                $result.Skipped | Should -Not -BeTrue

                # Verify refresh was called with correct seriesId
                Should -Invoke Invoke-SAArrSeriesRefresh -Times 1 -ParameterFilter {
                    $SeriesId -eq 100
                }

                # Verify scan was called twice
                Should -Invoke Invoke-SAArrManualImportScan -Times 2
            }
        }
    }

    Context 'TBA rejection persists after refresh' {
        It 'should return warning with TBA hint' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Write-SAPhaseHeader {}

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Test-SAArrConnection { return $true }
                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
                Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }

                $capturedMessages = @()
                Mock Add-SAEmailException {
                    $script:capturedMessages += $Message
                }

                # Both scans return TBA rejection
                Mock Invoke-SAArrManualImportScan {
                    return [PSCustomObject]@{
                        Success      = $true
                        ScanResults  = @(
                            @{
                                path       = 'C:\Test\S01E01.mkv'
                                quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                episodes   = @( @{ id = 200 } )
                                rejections = @( @{ type = 'permanent'; reason = 'Episode has a TBA title and recently aired' } )
                            }
                        )
                        ErrorMessage = $null
                    }
                }

                Mock Invoke-SAArrSeriesRefresh {
                    return [PSCustomObject]@{ Success = $true; Message = 'Completed' }
                }

                Mock Get-SAImportHint { return 'test hint' }

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test'

                $result.Success | Should -BeTrue
                $result.Skipped | Should -BeTrue
                $result.ErrorType | Should -Be 'tba'

                # Verify hint was shown
                Should -Invoke Get-SAImportHint -Times 1 -ParameterFilter {
                    $ErrorType -eq 'tba'
                }
            }
        }
    }

    Context 'non-TBA rejection does not trigger refresh' {
        It 'should not call refresh for quality rejections' {
            InModuleScope 'Stagearr.Core' {
                Mock Write-SAVerbose {}
                Mock Write-SAProgress {}
                Mock Write-SAOutcome {}
                Mock Write-SAPhaseHeader {}
                Mock Add-SAEmailException {}
                Mock Get-SAImportHint { return $null }

                Mock Get-SAImporterBaseUrl {
                    return @{ Url = 'http://localhost:8989'; DisplayUrl = 'http://localhost:8989'; HostHeader = $null }
                }

                Mock Test-SAArrConnection { return $true }
                Mock Invoke-SAArrQueueEnrichment { return $ScanResults }
                Mock ConvertTo-SAArrMetadata { return @{ Title = 'Test Show'; Year = 2026 } }

                Mock Invoke-SAArrManualImportScan {
                    return [PSCustomObject]@{
                        Success      = $true
                        ScanResults  = @(
                            @{
                                path       = 'C:\Test\S01E01.mkv'
                                quality    = @{ quality = @{ id = 3 }; revision = @{ version = 1 } }
                                series     = @{ id = 100; title = 'Test Show'; year = 2026 }
                                episodes   = @( @{ id = 200 } )
                                rejections = @( @{ type = 'permanent'; reason = 'Not an upgrade for existing episode file(s)' } )
                            }
                        )
                        ErrorMessage = $null
                    }
                }

                Mock Invoke-SAArrSeriesRefresh {}

                $config = @{ apiKey = 'test-key'; host = 'localhost'; port = 8989; ssl = $false; urlRoot = ''; timeoutMinutes = 1 }
                $result = Invoke-SAArrImport -AppType 'Sonarr' -Config $config -StagingPath 'C:\Test'

                Should -Invoke Invoke-SAArrSeriesRefresh -Times 0
            }
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `pwsh -Command "Invoke-Pester Tests/TbaRefresh.Tests.ps1 -Output Detailed"`
Expected: The TBA integration tests FAIL (no TBA detection logic yet).

**Step 3: Implement TBA refresh+retry in `Invoke-SAArrImport` Step 5**

In `Modules/Stagearr.Core/Public/ImportArr.ps1`, replace the "All files rejected" block (lines 276-303) with:

```powershell
    # All files rejected - check for TBA before returning
    if ($rejectionSummary.IsAllRejected) {

        # TBA rejection: attempt metadata refresh + re-scan (Sonarr only)
        if ($errorType -eq 'tba' -and $AppType -eq 'Sonarr') {
            $seriesId = $null
            if ($null -ne $scanItems[0].series -and $scanItems[0].series.id) {
                $seriesId = $scanItems[0].series.id
            }

            if ($null -ne $seriesId) {
                Write-SAOutcome -Level Info -Label $label -Text "Episode title is TBA, refreshing series metadata..." -Indent 1

                $refreshResult = Invoke-SAArrSeriesRefresh -Config $Config -SeriesId $seriesId

                if ($refreshResult.Success) {
                    Write-SAOutcome -Level Success -Label $label -Text "Metadata refreshed, re-scanning..." -Indent 1

                    # Re-scan
                    $reScanResult = Invoke-SAArrManualImportScan -AppType $AppType -Config $Config -StagingPath $StagingPath
                    if ($reScanResult.Success) {
                        $scanItems = @($reScanResult.ScanResults)

                        # Re-enrich
                        if (-not [string]::IsNullOrWhiteSpace($DownloadId)) {
                            $enrichParams = @{
                                AppType     = $AppType
                                Config      = $Config
                                ScanResults = $scanItems
                                DownloadId  = $DownloadId
                            }
                            if ($null -ne $CachedQueueRecords -and @($CachedQueueRecords).Count -gt 0) {
                                $enrichParams.CachedQueueRecords = $CachedQueueRecords
                            }
                            $scanItems = Invoke-SAArrQueueEnrichment @enrichParams
                        }

                        # Re-extract metadata
                        $arrMetadata = ConvertTo-SAArrMetadata -ScanResult $scanItems[0] -AppType $AppType

                        # Re-filter
                        $importableFiles = Get-SAImportableFiles -ScanResults $scanItems
                        $rejectionSummary = Get-SARejectionSummary -ScanResults $scanItems
                        $errorType = Get-SAErrorTypeFromRejection -PrimaryReason $rejectionSummary.PrimaryReason

                        Write-SAVerbose -Text "Re-scan results: $($importableFiles.Count) importable, $($rejectionSummary.RejectedCount) rejected"

                        # Update skipped file paths
                        $skippedFilePaths = @()
                        foreach ($file in $scanItems) {
                            if ($null -ne $file.rejections -and $file.rejections.Count -gt 0) {
                                $hasPermanent = $file.rejections | Where-Object { $_.type -eq 'permanent' }
                                if ($null -ne $hasPermanent -and @($hasPermanent).Count -gt 0) {
                                    $skippedFilePaths += $file.path
                                }
                            }
                        }

                        # If now importable, skip to Step 6 (import)
                        if (-not $rejectionSummary.IsAllRejected -and $importableFiles.Count -gt 0) {
                            if ($rejectionSummary.IsPartialRejected) {
                                Write-SAOutcome -Level Warning -Label $label -Text $rejectionSummary.Message -Indent 1
                                Add-SAEmailException -Message "$label`: $($rejectionSummary.Message)" -Type Warning
                            }
                            # Fall through to Step 6 below
                            $tbaResolved = $true
                        }
                    }
                } else {
                    Write-SAVerbose -Text "RefreshSeries failed: $($refreshResult.Message)"
                }
            }
        }

        # Still all rejected after TBA refresh attempt (or non-TBA rejection)
        if (-not $tbaResolved) {
            Write-SAOutcome -Level Warning -Label $label -Text $rejectionSummary.Message -Duration (& $getDuration) -Indent 1
            Add-SAEmailException -Message "$label`: $($rejectionSummary.Message)" -Type Warning

            # Show hint for actionable rejections
            $hint = Get-SAImportHint -ErrorType $errorType -ImporterLabel $label
            if ($hint) {
                Write-SAProgress -Label "Hint" -Text $hint -Indent 2
            }

            $isQualityRejected = ($errorType -eq 'quality')

            return [PSCustomObject]@{
                Success         = $true  # Skip is not an error
                Message         = $rejectionSummary.Message
                Duration        = (& $getDuration)
                ImportedFiles   = @()
                SkippedFiles    = $skippedFilePaths
                SkippedCount    = $rejectionSummary.RejectedCount
                ArrMetadata     = $arrMetadata
                Skipped         = $true
                QualityRejected = $isQualityRejected
                ErrorType       = $errorType
            }
        }
    }
```

Also add `$tbaResolved = $false` near the top of the function (after `$skippedFilePaths` initialization or with the other variable declarations before Step 1).

Note: The existing hint display was only for `quality` error type. The new code shows hints for ALL error types, which is the correct behavior now that we have hints for tba, disk-space, scene-mapping, etc.

**Step 4: Run tests to verify they pass**

Run: `pwsh -Command "Invoke-Pester Tests/TbaRefresh.Tests.ps1 -Output Detailed"`
Expected: ALL tests PASS.

**Step 5: Run all existing import tests**

Run: `pwsh -Command "Invoke-Pester Tests/ImportArr*.Tests.ps1 Tests/RejectionMappings.Tests.ps1 -Output Detailed"`
Expected: ALL tests PASS. If any fail due to the email prefix change or hint expansion, fix the assertions.

**Step 6: Commit**

```bash
git add Modules/Stagearr.Core/Public/ImportArr.ps1 Tests/TbaRefresh.Tests.ps1
git commit -m "feat: detect TBA rejections and refresh series metadata before retry"
```

---

### Task 6: Version Bump and Final Verification

**Files:**
- Modify: `Modules/Stagearr.Core/Stagearr.Core.psd1` (version 2.5.0 -> 2.5.1)

**Step 1: Bump version**

In `Modules/Stagearr.Core/Stagearr.Core.psd1`, change:
```powershell
ModuleVersion = '2.5.1'
```

**Step 2: Run all tests**

Run: `pwsh -Command "Invoke-Pester Tests/ -Output Detailed"`
Expected: ALL tests PASS.

**Step 3: Commit**

```bash
git add Modules/Stagearr.Core/Stagearr.Core.psd1 docs/plans/2026-03-30-tba-rejection-handling-design.md docs/plans/2026-03-30-tba-rejection-handling-impl.md
git commit -m "chore: bump version to 2.5.1"
```
