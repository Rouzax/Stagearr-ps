# Design: Filter Non-Content RARs from Detection

**Date:** 2026-03-29
**Status:** Approved

## Problem

Any `.rar` file in the source folder triggers RAR mode (`IsRarArchive = true`), even proof/sample/nfo RARs that don't contain video content. When RAR mode activates on a non-content RAR, the system extracts it, finds no video files, and fails with "Staging: No files ready" -- completely ignoring the actual video file sitting in the source folder.

**Real-world failure:** `The.Rule.Of.Jenny.Pen.2024.German.DL.2160p.UHD.BluRay.HEVC-TM` had a 1.1 MB proof RAR (`tm-theruleofjenny-2160p-hevc-proof.rar`) alongside the main video. The proof RAR was extracted, yielded no video, and the job failed.

## Solution

Filter non-content RARs by filename pattern at both RAR detection points. If no content RARs remain after filtering, the system falls through to normal video file detection.

### Non-Content RAR Patterns

Case-insensitive match against RAR filename (without extension):
- `proof` -- quality proof screenshots
- `sample` -- sample clips
- `nfo` -- release info files

### Changes

#### 1. Constants.ps1 -- Add pattern list

Add `NonContentRarPatterns` to `$script:SAConstants` containing the list of non-content keywords. Centralizes the patterns for discoverability and future tuning.

#### 2. PathSecurity.ps1 -- Add Test-SANonContentRar function

New function `Test-SANonContentRar` that tests if a RAR filename matches any non-content pattern. Follows the same style as existing `Test-SASamplePath`.

#### 3. Context.ps1:156-160 -- Filter during IsRarArchive detection

After `Get-ChildItem -Filter '*.rar'`, filter results through `Test-SANonContentRar`. Only set `IsRarArchive = $true` if content RARs remain. Emit verbose log for each skipped non-content RAR.

#### 4. Staging.ps1:212-216 -- Filter during RAR file selection

In `Get-SASourceMediaFiles`, apply the same filter when selecting the main RAR file. This is defense-in-depth -- Context.ps1 should already prevent reaching this path for non-content-only folders, but filtering here too ensures consistency.

### Logging

When non-content RARs are skipped, emit: `[VERB] Skipped non-content RAR: <filename>`

### Testing

- Folder with only proof RAR + standalone video: should process the video, not the RAR
- Folder with content RAR + proof RAR: should extract the content RAR, ignore the proof RAR
- Folder with only content RAR: unchanged behavior
- Folder with no RARs: unchanged behavior
