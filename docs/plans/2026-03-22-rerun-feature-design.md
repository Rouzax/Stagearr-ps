# Design: -Rerun Interactive Job Re-runner

**Date:** 2026-03-22
**Status:** Approved

## Summary

Add a `-Rerun` CLI flag that shows recent completed and failed jobs in a numbered list, lets the user pick one, and re-runs it with `-Force -Wait` behavior.

## CLI Interface

```powershell
.\Stagearr.ps1 -Rerun        # shows last 10 completed + failed jobs
.\Stagearr.ps1 -Rerun 20     # shows last 20
```

`-Rerun` is its own parameter set with an optional `[int]` positional parameter (default 10). `-Force` and `-Wait` are applied automatically when a job is selected.

## Display Format

```
Recent Jobs
-----------
 #   State      Date            Label   Name
 1   Failed     22-03-26 14:23  Movie   Movie.2024.1080p.BluRay-GROUP
 2   Completed  22-03-26 14:01  TV      Show.S01E05.720p.WEB-DL-GROUP
 3   Failed     21-03-26 13:45  Movie   Another.Movie.2023.2160p-GROUP

Enter job number to re-run (or 'q' to quit):
```

- Shows completed + failed jobs, sorted most recent first
- Failed jobs highlighted with color
- Date format: `dd-MM-yy HH:mm` (international)
- On selection, confirmation prompt before processing:
  ```
  Re-run "Movie.2024.1080p.BluRay-GROUP" [Movie]? (y/n): y
  ```
- `q`, empty input, or invalid number exits cleanly

## Implementation

### New file: `Public/Rerun.ps1`

Single new public function: `Invoke-SARerun`

**Responsibilities:**
1. Load config
2. Call `Get-SAJobs` for `failed` and `completed` states with user's limit
3. Merge and sort by timestamp descending
4. Render numbered table to console with `Write-Host`
5. `Read-Host` loop for job number (validate range, handle `q`/empty)
6. `Read-Host` for y/n confirmation
7. On confirm: call existing processing path with the job's original `input` block (`downloadPath`, `downloadLabel`, `torrentHash`, etc.) plus `-Force -Wait`

### Changes to existing files

- **Stagearr.ps1:** Add `Rerun` parameter set with `[int]$Rerun` parameter. Add branch in main switch to call `Invoke-SARerun`.
- **Stagearr.Core.psd1:** Add `Invoke-SARerun` to `FunctionsToExport`.

### What it reuses (no changes needed)

- `Get-SAJobs` -- fetch jobs by state
- `Add-SAJob` -- re-create job with `-Force`
- `Start-SAWorker` -- process with `-Wait`
- Job JSON schema unchanged

### What it does NOT do

- No new output events -- interactive CLI flow uses `Write-Host` directly (same as `-Status` and `-Setup`)
- No new queue functions
- No changes to job JSON schema
