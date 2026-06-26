# Changelog

All notable changes to this project are documented here. This file starts at v2.10.0; for earlier history see the [GitHub Releases](https://github.com/Rouzax/Stagearr-ps/releases).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Removed dead PowerShell 5.1 compatibility code now that PowerShell 7.0 is required: TLS 1.2 forcing in HTTP/OMDb/email/update paths, and the `$IsWindows` and `Invoke-WebRequest -UseBasicParsing` polyfills. No behavior change on PowerShell 7.

## [2.10.0] - 2026-06-26

### Added
- **seconv subtitle-cleanup engine.** Auto-detected from the `tools.subtitleEdit` path (install folder or binary; seconv is preferred over the SubtitleEdit GUI when both are present), enabling cross-platform cleanup. Ships a bundled SE4-profile settings JSON (override via `subtitles.cleanup.seconvSettings`), validated to roughly 99.7% output parity with SubtitleEdit 4.0.16.
- New `[subtitles.cleanup]` options: `removeHearingImpaired`, `mergeSameTexts`, `fixCommonErrors`, `splitLongLines`, plus the seconv-only `fixCommonErrorsRules` and `seconvSettings`. The seconv engine requires SubtitleEdit/seconv v5.1.0-beta1 or newer.

### Changed
- **Breaking:** Stagearr now requires PowerShell 7.0. Windows PowerShell 5.1 is no longer supported.

### Notes
- Existing configs that point `tools.subtitleEdit` at `SubtitleEdit.exe` continue to use the GUI engine unchanged.
- seconv does not perform dictionary or OCR-error repair (the GUI's `FixCommonOcrErrors` rule is excluded from the CLI); it applies structural, formatting, casing, punctuation, and timing fixes.

## [2.9.5] - 2026-06-23

### Fixes

#### TBA retry handling
- **Honor the retry delay on every system locale.** On non-US date cultures (for example nl-NL/Dutch), a scheduled TBA retry was parsed incorrectly and fired immediately instead of waiting. That burned the single retry, removed the staged files, and never rescheduled, so the release was effectively skipped. Retries now wait the full window regardless of locale.
- **A pending retry no longer shows as completed.** Previously a TBA-rejected job could appear as both pending and completed at once (and as completed under `-Rerun`) while a retry was genuinely waiting. The job now stays as a single pending retry until it runs.

#### Culture-safe matching (Turkish/Azeri locales)
- Dangerous-extension checks, language-code resolution, email subject style/template names, *arr rejection-reason mapping, and the OpenSubtitles upload blocklist now use invariant case folding. Identifiers containing `I`/`i` (for example `.MSI`, language codes like `id`/`fi`) now match correctly under `tr-TR`/`az` locales.

## [2.9.4] - 2026-06-22

### Fix: TBA retry now fires at 49h to clear Sonarr's TBA window

When Sonarr rejects an episode import because the title is still **TBA**, Stagearr schedules an automatic retry. That retry was scheduled exactly 48 hours later, which could land right on the boundary of Sonarr's own 48h TBA auto-accept window and still be rejected.

- The automatic TBA retry now fires at **49 hours** (was 48), giving a 1-hour margin so the retry runs safely past Sonarr's window.
- Documentation describing the scheduled retry was updated to match.

No configuration or behavior changes beyond the retry timing. References to Sonarr's own 48h auto-accept behavior are unchanged because that describes Sonarr, not Stagearr.

## [2.9.3] - 2026-06-20

### Fix: MDBList marks fully-downloaded TV shows at the show level

2.9.0 marked TV only at the episode level, but MDBList's list filters (e.g. "not collected") only treat a show as collected when it has a **show-level** entry. Per-episode marking did not remove a show from those lists, even at 100% episode coverage.

- A **fully-downloaded** show (all aired, monitored episodes on disk) is now marked at the show level, so it drops off "not collected" lists.
- A **partial** show is still marked per-episode, so it stays on "get more" lists until you are caught up.
- Trakt-safe: a whole-show entry is only created when the show is genuinely complete.
- Movies are unchanged (already correct).

Also: CI now gates on PowerShell parse errors, and local pre-commit hooks were added that mirror the CI lint/test jobs.

## [2.9.2] - 2026-06-17

### Fixes

**Import verification could turn successful imports into failures.** Since v2.9.1, the import verification window (`-Since`) mishandled history timestamps: dates parsed by `ConvertFrom-Json` arrive as UTC `[datetime]` values, but were stringified and re-parsed in a way that shifted them backward by the host's UTC offset. On any host east of UTC this pushed every current-run import before the cutoff, so verification reported 0 files imported.

Symptoms this resolves:
- **Sonarr:** successful imports flagged with a false "imported 0 of N (some silently skipped)" warning.
- **Radarr:** successful imports reported as hard failures, because the benign post-import `NullReferenceException` could no longer be recovered.

No data was lost by the bug; it only mis-reported imports that had actually succeeded.

## [2.9.1] - 2026-06-16

Bug-fix release.

### Fixes

- **Import verification scoped to the current run.** `Get-SAImportVerification` previously counted all-time `downloadFolderImported` history events for a download hash. Because the *arr history is retained indefinitely, a hash re-imported on a later run (an upgrade or `-Rerun`) accumulated multiple events, producing a confusing "2 of 1 files confirmed imported" message and, for season packs, a possible false "complete" that masked silently skipped files. Verification is now scoped to events at or after the current run's start time.

- **Clearer OpenSubtitles failure message.** A login failure caused by an upstream outage (HTTP 500/504) previously reported a flat "Authentication failed", which read like a credentials problem. The warning now distinguishes a real credential rejection (401/403) from OpenSubtitles being unavailable (server error / timeout).

No configuration changes required.

## [2.9.0] - 2026-06-15

### MDBList collection sync

After a successful import, Stagearr can now mark the item as **collected / In Library** on [MDBList](https://mdblist.com) (opt-in, free account, no Patreon needed). Movies are marked at the title level and TV at the episode level, using the tmdb/tvdb/imdb IDs Radarr/Sonarr already provide. It is best-effort: a failure never fails the job.

Enable it with a new `[mdblist]` section in `config.toml` (or via `-Setup`). See the [MDBList Collection Sync](https://rouzax.github.io/Stagearr-ps/docs/mdblist/) docs.

#### Also in this release
- **CI:** new GitHub Actions workflow running PScriptAnalyzer (lint) and the Pester suite (tests previously did not run in CI), plus a tuned `PSScriptAnalyzerSettings.psd1`.
- **Cleanup:** removed em-dashes from PowerShell comments (PS 5.1 encoding safety).

## [2.8.0] - 2026-06-10

### Safer self-updates

Hardens the ZIP self-update path so an update can no longer corrupt an install or collide with a running job. No config changes; most users need no action.

#### Atomic apply with rollback
- Each release file is staged, the existing one is backed up, then swapped into place. On the same disk these moves are effectively atomic.
- If anything fails partway (disk full, locked file, interrupted run), every completed swap is rolled back from its backup, so the previous working install is left intact. A failed or interrupted update can no longer leave `Modules/` deleted-but-not-replaced.

#### Orphan pruning
- Files that a previous release shipped but the new one removed or renamed (for example a module script) are now deleted on update, so stale code cannot be loaded alongside the updated files.
- Pruning is bounded to the files the release owns (`Stagearr.ps1`, `Modules/`, `config-sample.toml`, `LICENSE`, `README.md`). User data is never touched: `config.toml`, `queueRoot/`, `logArchive/`, `stagingRoot/`, and `.git` are all left intact.

#### Updates never run while a job is processing
- An update is applied only when no other worker holds the global lock. If a second run starts mid-job (for example two torrents finishing close together), the update is deferred to a later check instead of being applied on top of the running worker.
- `-Update` behaves the same way: if a worker is busy it reports the update as deferred and asks you to re-run when idle (check with `.\Stagearr.ps1 -Status`).

#### Unchanged
- Whole-ZIP SHA256 verification still runs before extraction; a corrupted or tampered download is rejected.

#### Upgrade note
Because this release changes the updater itself, the safe-apply behavior takes effect on the **next** update after this one. Run `.\Stagearr.ps1 -SyncConfig` after updating; no new settings were added in this release.

## [2.7.0] - 2026-06-10

### Heartbeat-based global lock

Replaces the wall-clock stale-lock timeout with a heartbeat-based global lock. This fixes a bug where a long-running job (for example, staging a large remux) could have its lock stolen by a second worker, causing the same download to be imported twice.

#### What changed
- The lock holder now refreshes a heartbeat every 30s. Another worker only takes over a lock after 120s with no heartbeat, so a live worker is never displaced no matter how long the job runs.
- Atomic compare-and-swap takeover when a lock is genuinely dead (also fixes a latent remove-then-create race).
- Works across two machines that share a queue folder (assumes NTP-synced clocks).
- An import-time ownership guard plus phase-boundary checks prevent a double import even in rare freeze-then-recover cases.

#### Breaking config change
`processing.staleLockMinutes` has been removed and replaced by two settings (defaults shown):

- `heartbeatSeconds = 30`
- `staleHeartbeatSeconds = 120`

If you customized `staleLockMinutes`, remove it. Run `.\Stagearr.ps1 -SyncConfig` to reconcile your config. Most users need no action.

#### Upgrade note
Upgrade all machines that share a queue folder together.

## [2.6.0] - 2026-06-03

### TBA Auto-Retry for Sonarr Imports

When Sonarr rejects an import because the episode title is "TBA" (common for recently-aired episodes), Stagearr now automatically schedules a retry job for 48 hours later.

#### How it works

1. **Immediate refresh:** On the first run, Stagearr refreshes the series metadata in Sonarr and re-scans. If the title is now available, the import proceeds normally.
2. **Auto-retry:** If the title is still TBA, a retry job is scheduled for 48 hours later. Sonarr auto-accepts TBA titles after 48 hours.
3. **Import-only retry:** Staged files are preserved so the retry skips video/subtitle processing and goes straight to import. If staged files are gone, it falls back to a full pipeline re-run.
4. **One retry only:** If the automatic retry also fails, a warning email is sent with instructions to use `-Rerun` manually.

The retry runs on the next torrent completion after the 48-hour window. No additional setup or scheduled tasks required.

#### Email notifications

- **Original run:** Shows `Import: Pending retry` with the expected retry date (informational tone, not a warning)
- **Retry success:** Full normal email with a note that it was an automatic retry
- **Retry failure:** Warning email with `-Rerun` instructions

#### Queue changes

- `Add-SAJob` now accepts `-RetryAfter`, `-TbaRetry`, and `-StagingPath` parameters
- `Get-SANextPendingJob` skips jobs whose `retryAfter` timestamp is still in the future
- Existing queue behavior is unchanged for non-retry jobs

#### Testing

26 new tests across 4 test files. 192 total tests pass.

## [2.5.5] - 2026-05-09

### Fixes

- **GuessIt API array field crash**: The OpenSubtitles GuessIt API can return `source` and `streaming_service` as arrays instead of strings. When this happened, `Get-SASourceDisplayName` threw "Cannot process argument transformation on parameter 'Source'. Cannot convert value to type System.String", crashing the entire job at startup. Both fields are now normalized to scalars in `Get-SAGuessItInfo`, matching the existing pattern used for the `other` field.

## [2.5.4] - 2026-05-07

### Fixes

- **Pipeline leak in `Test-SAProcessResult` swallowed mkvmerge errors**: `Write-SAToolError` returns an `$errorInfo` object which leaked into `Test-SAProcessResult`'s output pipeline, making it return `@($errorInfo, $false)` instead of just `$false`. PowerShell evaluates non-empty arrays as truthy, so callers (`Start-SAMkvRemux`, `Start-SARemuxMP4`) treated failures as successes — deleting the original file and continuing with a corrupt partial output. The import then failed on the truncated file (e.g. Radarr rejecting it as "Sample") with no indication of the real cause.
- **Generic email on video processing failure**: When video processing failed, the email showed "Phase: Processing" / "Error: An error occurred" because the result objects never populated `Error` or `FailedFile`. These properties are now set on all failure paths (MKV analysis, subtitle stripping, MP4 remux) and propagated through `Invoke-SAVideoProcessing`, so the email shows the actual failure (e.g. "Remux failed during subtitle stripping") with context-aware troubleshooting suggestions.

## [2.5.3] - 2026-04-08

### Fixes

- **Misleading "Imported 1 file" note**: When Sonarr/Radarr `ManualImport` silently failed (e.g. an existing episode file was locked by Plex/Kodi/Emby and couldn't be deleted to make room for an upgrade), the email Notes section emitted "Imported 1 file" alongside the correct "Imported 0 files" main result. `ImportedFiles` is now populated only after history verification confirms the import, so the email Notes reflect what actually happened.
- **Verbose surfacing of silent ManualImport failures**: `Wait-SAImporterCommand` now logs `exception`, `message`, and `completionMessage` from the `*arr` command response on terminal states. Silent failures (where the command completes without throwing but no files actually move) are now visible in the Stagearr verbose log without having to dig through `sonarr.txt`.
- **Defensive `Get-SAImportableFiles` array shape**: Returns `, $importable` so a single-element result preserves array shape across the function boundary instead of being unwrapped to a scalar.

## [2.5.2] - 2026-03-30

### Fixes

- **Sample file detection**: Files named `Sample.mkv` at the release root are now excluded from staging. Previously only `\Sample\` subdirectories and `.sample.` mid-filename patterns were detected.
- **Email terminology**: Movie downloads now correctly show "video/videos" instead of "episodes" in the email Files row. "Episodes" is now only used for TV content (Sonarr/Medusa).

## [2.5.1] - 2026-03-30

### What's New

#### TBA Episode Title Handling
- When Sonarr rejects an import because the episode title is "TBA" (common for recently-aired shows), Stagearr now automatically refreshes the series metadata and retries the import
- If the title is still TBA after refresh, a clear hint is shown: "Sonarr auto-accepts TBA titles after 48 hours. Use -Rerun to retry."

#### Improved Import Rejection Messages
- All import rejection messages in emails and logs now show which importer (Sonarr/Radarr) produced the rejection
- 10 new rejection categories with user-friendly names: Episode title TBA, Not enough disk space, Unverified scene mapping, No audio tracks, Full season file, Partial season pack, Missing absolute episode number, Unexpected episode, Existing file has more episodes
- Actionable hints for all rejection types (disk space, scene mapping, corrupt files, etc.)

#### Before/After

**Email notes before:**
`1 file skipped (Episode has a TBA title and...)`

**Email notes after:**
`Sonarr: 1 file skipped (Episode title TBA)`

## [2.5.0] - 2026-03-29

### What's New

#### Bug Fix: Non-content RAR filtering

Fixed an issue where proof, sample, or NFO RAR archives in a download folder would incorrectly trigger RAR extraction mode, causing the actual video file to be ignored entirely.

**Example:** A download containing `movie.mkv` + `group-proof.rar` (1.1 MB proof image) would extract the proof RAR, find no video files, and fail -- instead of processing the MKV.

#### Changes

- Added `Test-SANonContentRar` function to detect proof/sample/nfo archives by filename pattern
- RAR detection now filters out non-content archives before deciding whether to enter RAR mode
- Defense-in-depth filtering in RAR file selection during staging
- Verbose logging when non-content RARs are skipped

## [2.4.2] - 2026-03-22

### Bug Fixes

- **fix(http):** Coerce byte[] response content to string for PS Core compatibility -- Sonarr DELETE responses returned empty body as byte[], causing blocklist success to be swallowed and retries to fail with 404
- **fix(email):** Populate failure details (phase, error, path) for dangerous file detections -- "What Happened" card now shows "Security" phase with actual file names instead of generic defaults

### Features

- **feat(email):** Add "Blocked" subject prefix for dangerous file detections -- email subject now reads "Blocked: TV: ..." instead of "Failed: TV: ...", with "BLOCKED" status badge
- **feat(email):** Add security-specific troubleshooting suggestions -- "What to Check" card now shows malware-specific guidance (blocklist confirmation, report to indexer) instead of generic suggestions

## [2.4.1] - 2026-03-22

### Bug Fixes

#### Orphan recovery no longer crashes on temp files
Atomic write temp files (`.tmp.<PID>.<hash>.json`) in the `running/` queue directory were being picked up by orphan recovery, causing warnings on every worker start. They are now filtered out and cleaned up automatically.

#### Cross-server `-Rerun` with `paths.downloadRoot`
New `paths.downloadRoot` config setting enables `-Rerun` on multi-server setups sharing a queue folder. Each server sets its own download root path; Stagearr translates stored paths when re-running jobs from another server.

```toml
[paths]
downloadRoot = "D:/TEMP/Torrent/Downloads"
```

#### Download path validation before re-run
`-Rerun` now checks if the download path still exists before dispatching. Shows a clear error if source files have been removed after import.

#### Mailozaurr v1.x compatibility
Email sending no longer crashes when Mailozaurr v1.x is installed. Inline poster images (which require v2.x) are gracefully skipped with a verbose log message. Plain email sending works on both versions.

#### ManualImport scan now passes seriesId/movieId
When re-running completed jobs, the ManualImport scan now includes the series/movie ID from the history lookup. This prevents "Unknown Series" / "Unknown Movie" rejections when Sonarr/Radarr can't identify the content from the filename alone. History data is also cached for the enrichment pipeline as a fallback.

#### Files Changed
- `Public/Queue.ps1` -- Temp file filter in orphan recovery; `downloadRoot` in job input
- `Public/Rerun.ps1` -- Path translation + validation
- `Public/Notification.ps1` -- Mailozaurr version check
- `Public/JobProcessor.ps1` -- Cache media ID from history, wrap history in queue structure
- `Public/Import.ps1` -- Pass media ID to importers
- `Public/ImportArr.ps1` -- Add `MediaId` param to scan functions, append to URL
- `Private/Config.ps1` -- `downloadRoot` default
- `config-sample.toml` -- `downloadRoot` setting
- `Stagearr.ps1` -- Pass `downloadRoot` through to job params
- `Tests/OrphanRecovery.Tests.ps1` -- New: 3 tests
- `Tests/Rerun.Tests.ps1` -- 3 new tests

## [2.4.0] - 2026-03-22

### What's New

#### Interactive Job Re-runner (-Rerun)

New `-Rerun` flag to interactively re-run recent completed or failed jobs without needing to remember the original download path and label.

```powershell
## Show last 10 completed/failed jobs and pick one to re-run
.\Stagearr.ps1 -Rerun

## Show last 20 jobs
.\Stagearr.ps1 -Rerun -RerunLimit 20
```

Displays a numbered table with state (color-coded), date, label, and name. Pick a number, confirm, and it re-runs with `-Force -Wait` so you see full console output.

#### Files Changed
- `Public/Rerun.ps1` -- New: `Get-SARerunJobList`, `Invoke-SARerun`
- `Stagearr.ps1` -- Added `-Rerun` and `-RerunLimit` parameter set
- `Stagearr.Core.psm1` / `Stagearr.Core.psd1` -- Registered new module
- `Tests/Rerun.Tests.ps1` -- New: 4 tests for job listing and edge cases

## [2.3.0] - 2026-03-21

### What's New

#### Security: Dangerous File Detection & Blocklisting

Stagearr now detects downloads containing only executable/script files (`.exe`, `.msi`, `.bat`, `.scr`, `.lnk`, etc.) disguised as TV/Movie releases -- a pattern seen with fake torrents uploaded to indexers using legitimate scene group names.

When detected:
- **Blocklists** the release in Sonarr/Radarr (prevents re-grab)
- **Removes** the download from qBittorrent
- **Fails** the job with a clear security error in the log and email notification

This check only applies to TV/Movie labels. Passthrough jobs are unaffected and continue to handle any file type.

#### Files Changed
- `Private/Constants.ps1` -- Added `DangerousExtensions` list
- `Private/SafetyCheck.ps1` -- New: `Test-SADangerousDownload`, `Remove-SAArrQueueItem`
- `Stagearr.Core.psm1` -- Registered new module
- `Public/JobProcessor.ps1` -- Integrated safety check into TV/Movie processing

## [2.2.0] - 2026-03-20

### Stagearr v2.2.0

ZIP-based auto-update system — replaces git pull with release asset downloads.

#### New Features

- **ZIP-based auto-update** — Updates now download release ZIPs from GitHub instead of requiring Git. Works for all users regardless of install method.
- **SHA256 checksum verification** — Downloaded updates are verified against checksums before applying.
- **GitHub Actions release workflow** — Release ZIPs and checksums are automatically built and attached when a release is published.

#### Internal

- Removed `Invoke-SAGitPull` — replaced by `Invoke-SAZipUpdate` and `Invoke-SADownloadFile`
- Extended `Get-SALatestRelease` to scan release assets for ZIP and checksum URLs
- Added zip-slip path validation using existing `Assert-SAPathUnderRoot`
- Added `UpdateAssetPattern` and `UpdateChecksumFile` constants

## [2.1.5] - 2026-03-19

### Fix: Radarr ManualImport downloadId placement

**Bug:** Post-import verification reported "Imported 0 files" as a warning even when Radarr successfully imported the file. This caused false warning emails.

**Root cause:** Radarr's `ManualImportFile` expects `downloadId` per-file, but `ManualImportCommand` has no such property at command level. Our code sent it at command level where it was silently ignored during JSON deserialization. Radarr's fallback `FindDownloadId()` fails for movies with multiple grab events (upgrades), leaving history records without `downloadId` -- making our verification unable to confirm the import.

**Fix:** Send `downloadId` per-file for both Radarr and Sonarr, matching the actual API contract confirmed from Radarr/Sonarr source code. Also generalized NRE recovery to cover both apps.

#### Changes
- `fix(import)`: Send downloadId per-file for Radarr ManualImport
- `test`: Radarr downloadId placement test + Radarr NRE recovery test

## [2.1.4] - 2026-03-18

### Bug Fixes

- **Import:** Surface partial Arr imports in email notifications -- when Sonarr/Radarr silently skips files (e.g., file in use), the email now reports which files were not imported with a warning
- **Email:** Suppress "Up to Date" card when there is nothing actionable to report

### Tests

- Added tests for partial Arr import verification
- Updated email update section test for new behavior

## [2.1.3] - 2026-03-17

#### Bug Fix

- **Import:** Recover from Sonarr NullReferenceException when import actually succeeded. Sonarr's tracked download path can throw NRE after the file is already imported; Stagearr now verifies via history API before reporting failure.

## [2.1.2] - 2026-03-16

### Bug Fixes

- **Radarr import**: Fix NullReferenceException caused by sending `downloadId` per-file instead of on the command body. Radarr and Sonarr have different API contracts -- downloadId is now placed correctly for each app.
- **PS5 email timeout**: Add TLS 1.2 enforcement in the `Send-MailMessage` fallback job, fixing SMTP handshake hangs on PowerShell 5.1 when Mailozaurr is not installed.
- **Auto-update default**: Change default `updates.mode` from `off` to `auto` so auto-update works out of the box.
- **Update failure handling**: When `git pull` fails (e.g., diverged history), fall back to notify mode instead of reporting an error. Email shows amber "Update Available" card.
- **Email timeout constant**: Use `EmailSendTimeoutSeconds` from constants instead of hardcoded value.

### Improvements

- **Tool logging**: Log Mailozaurr module availability (version or "not installed") alongside other external tools in both console and log file output.
- Gitignore config backup files (`config.toml.backup-*`)

## [2.0.7] - 2026-03-16

### What's New

#### Features
- **Upload exclude list** - Skip subtitle uploads for specific shows/movies by IMDB ID or title (`uploadExclude` config setting). Useful for shows with bad embedded subtitles
- **Import verification** - Verify actual import count from *arr history after ManualImport completes, detecting silently skipped files

#### Fixes
- **OpenSubtitles rate limiting** - Add 250ms delay between API calls (search and upload eligibility checks) to prevent 429 errors on season packs
- **Redundant log output** - Demote duplicate "No subtitles found" message to verbose (the batch-aware `!: [n/N] Language not available` line remains at info)
- **Import downloadId** - Send downloadId per-file in ManualImport command for reliable queue matching

#### Documentation
- Added subtitle upload documentation to wiki (guards, exclude list, diagnostic mode)
- Added upload functions to FUNCTION-REFERENCE.md
- Added Sonarr/Radarr prerequisite setup instructions to wiki
- Added update notification card to landing page email showcase

## [2.0.6] - 2026-03-13

#### What's New
- **Log header: version and update status** - The file log header now includes the running Stagearr version and the result of the update check (up to date / update available / auto-updated). Previously, update check results were only visible in console and email.

## [2.0.5] - 2026-03-13

#### Bug Fix
- **Fix PS5 parse error in Update.ps1** — Em dash characters (`—`) inside double-quoted strings caused PowerShell 5.1 to fail parsing the file. PS5 reads UTF-8 files without BOM using Windows-1252, where the em dash byte `0x94` maps to a smart double quote `"`, which PS5 treats as a string terminator. Replaced with ASCII dashes.

## [2.0.4] - 2026-03-13

#### What's New
- **Email: up-to-date confirmation** — The email notification now shows a gray card when the update check ran but no update is available, giving visual confirmation the check executed successfully.

#### Details
- Three update card states in email: green (updated), amber (update available), gray (up to date)

## [2.0.3] - 2026-03-13

### What's New

#### Auto-Update Support
Stagearr can now check for new releases automatically and optionally self-update via `git pull`.

```toml
[updates]
mode = "notify"         # "auto", "notify", or "off"
checkIntervalHours = 24
```

- **notify** — Shows update available in email and console
- **auto** — Automatically pulls updates before processing
- **off** — Disables update checking (default)

Update notifications appear as a dedicated section in the email with a colored left bar (green for applied, amber for available) and a link to the release notes.

#### OpenSubtitles Upload Guards
- Upload guard system prevents uploading unsuitable subtitles (generic filenames, wrong label types)
- Diagnostic mode (`uploadDiagnosticMode = true`) logs what would be uploaded without actually uploading
- Upload guard warnings now written to file log instead of console only

#### Queue-Based Scan Enrichment
- ManualImport scan results are now enriched with data from the *arr download queue
- Early queue lookup improves OMDb metadata resolution accuracy
- History API fallback when queue returns no records
- Fixes for episode number parsing, nested arrays, and PSCustomObject property assignment

#### Landing Page
- New GitHub Pages landing page with pipeline visualization, email showcase, and integrations overview

### Bug Fixes
- Fix manifest path resolution in email footer version lookup
- Fix queue record client-side filtering by downloadId
- Inline SVG icons and add scroll indicator to hero section

### Housekeeping
- Auto-deploy site to gh-pages on push
- Reorganized docs/plans directory structure
- Version comment in Stagearr.ps1 synced with module manifest

## [2.0.2] - 2026-03-07

### What's Changed

#### Unified metadata flow
- **Fixed**: Poster corruption in email notifications — posters now always come from OMDb (~25KB, reliable) instead of external CDNs that could truncate on slow connections
- **Improved**: Single OMDb API call early in pipeline, cached for both subtitle upload (IMDB ID) and email enrichment — eliminates duplicate API calls
- **Improved**: Email metadata merges *arr ratings/genre/plot with OMDb poster for best of both worlds
- **Removed**: Dead `poster.size` config option (`notifications.email.metadata.poster.size`) — OMDb poster is used as-is
- **Removed**: Local *arr poster download code (was unreliable due to ManualImport API not returning images for Sonarr)
- **Cleaned up**: Removed unused functions (`Get-SAArrPosterData`, `Get-SAArrMetadataFromScan`, `Get-SAEmailMetadataSource`) — net reduction of ~450 lines

## [2.0.1] - 2026-03-07

### What's New

- **Fix `-Wait` race condition** — Jobs are no longer stolen by the background worker when using `-Wait`. Job creation is deferred until the lock is acquired.
- **Fix `-Verbose` flag** — Console output now works correctly with `-Verbose`, including proper propagation through the output system.
- **Cross-platform unicode safety** — Unicode literals replaced with `[char]` codes to avoid encoding issues across PowerShell hosts.
- **Version now read from module manifest** — No more hardcoded version strings in the entrypoint.

## [2.0.0] - 2026-03-06

### Stagearr-ps v2.0.0

Complete rewrite of [TorrentScript](https://github.com/Rouzax/TorrentScript) — rebuilt from the ground up with a modular architecture and many new features.

#### Highlights

- **Modular PowerShell module** — Clean separation of public API and private helpers with strict dependency ordering
- **Event-based output system** — Business logic emits structured events; console, file log, and email renderers handle presentation independently
- **Persistent job queue** — File-backed JSON queue with global locking, survives reboots and crashes
- **RAR extraction** — Automatic archive detection and extraction via WinRAR
- **Video processing** — MP4→MKV remux and subtitle track stripping via MKVToolNix
- **Subtitle pipeline** — Extract from MKV, download from OpenSubtitles API, clean with SubtitleEdit, with language-aware deduplication
- **Media server import** — Radarr, Sonarr, and Medusa integration via ManualImport API with scan → execute → poll workflow
- **Email notifications** — Dark-themed HTML emails with success/warning/failed/passthrough states, configurable subject templates, and metadata enrichment (posters, IMDb/RT/Metacritic ratings via OMDb)
- **Interactive setup wizard** — Guided configuration with validation
- **Config sync** — Detect missing/extra settings when upgrading
- **Label routing** — Automatic content-type detection with passthrough mode for unknown labels
- **Security** — Path traversal prevention, zip-slip protection, safe atomic operations

#### Requirements

- PowerShell 5.1+ or 7.x (Windows)
- [WinRAR](https://www.win-rar.com/), [MKVToolNix](https://mkvtoolnix.download/) (required)
- [SubtitleEdit](https://github.com/SubtitleEdit/subtitleedit), [Mailozaurr](https://github.com/EvotecIT/Mailozaurr) (optional)

#### Getting Started

See the [README](https://github.com/Rouzax/Stagearr-ps#-installation) for installation and the [Wiki](https://github.com/Rouzax/Stagearr-ps/wiki) for full documentation.

