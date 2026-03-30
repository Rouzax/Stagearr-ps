# TBA Rejection Handling & Improved Import Rejection Mappings

**Date:** 2026-03-30
**Status:** Approved

## Problem

When Sonarr rejects an episode import because the episode title is "TBA" (common for recently-aired shows like Last Week Tonight), Stagearr:

1. Shows a truncated, unclear message: `"1 file skipped (Episode has a TBA title and...)"`
2. Does not indicate the rejection came from Sonarr
3. Has no mechanism to refresh metadata and retry
4. Falls through to a generic truncated-text path for many other rejection types

### Sonarr TBA Rejection Details (from source)

- **File:** `EpisodeTitleSpecification.cs`
- **Conditions:** Episode aired within 48 hours AND title equals "TBA" (case-sensitive) AND naming format requires episode titles
- **Auto-accept:** After 48 hours, Sonarr accepts TBA titles automatically
- **Bypass options:** "Episode Title Required" setting set to `Never`, or rename format without `{Episode Title}`

## Scope

Three changes:

1. **Improved rejection mappings** - Comprehensive category mapping for all Sonarr/Radarr rejection types
2. **Email clarity** - Prefix rejection messages with importer name (Sonarr/Radarr)
3. **TBA inline refresh + retry** - Detect TBA rejection, refresh series metadata via Sonarr API, re-scan

## Design

### 1. Improved Rejection Mappings

Expand `Get-SASimplifiedRejectionReason` in `ArrMetadata.ps1` with new patterns:

| Sonarr rejection | Simplified text | Error type | Regex pattern |
|---|---|---|---|
| TBA title | `Episode title TBA` | `tba` | `tba title` |
| Title missing | `Episode title TBA` | `tba` | `does not have a title` |
| MinimumFreeSpace | `Not enough disk space` | `disk-space` | `free space\|not enough space` |
| UnverifiedSceneMapping | `Unverified scene mapping` | `scene-mapping` | `unverified.*scene\|xem\|scene.*mapping` |
| NoAudio | `No audio tracks` | `corrupt-file` | `no audio` |
| FullSeason | `Full season file` | `full-season` | `full season\|all episodes in season` |
| PartialSeason | `Partial season pack` | `partial-season` | `partial season` |
| MissingAbsoluteEpisodeNumber | `Missing absolute episode number` | `tba` | `absolute episode number` |
| EpisodeUnexpected | `Unexpected episode` | `episode-mismatch` | `unexpected.*considering` |
| ExistingFileHasMoreEpisodes | `Existing file has more episodes` | `episode-mismatch` | `more episodes` |

Add corresponding entries in `Get-SAErrorTypeFromRejection`.

### 2. Email Clarity - Source Attribution

In `Invoke-SAArrImport` (ImportArr.ps1), prefix the importer label when adding email exceptions:

```
Before: Add-SAEmailException -Message $rejectionSummary.Message -Type Warning
After:  Add-SAEmailException -Message "$label: $($rejectionSummary.Message)" -Type Warning
```

Apply to all `Add-SAEmailException` calls in the import flow. This produces messages like:
`"Sonarr: 1 file skipped (Episode title TBA)"`

### 3. TBA Inline Refresh + Retry

**Where:** `Invoke-SAArrImport` in ImportArr.ps1, at Step 5 (HANDLE REJECTIONS), before returning the "all rejected" result.

**Flow:**

```
TBA rejection detected (errorType == 'tba') AND AppType == 'Sonarr'
  +-- Extract seriesId from scan result ($scanItems[0].series.id)
  +-- LOG: "[INFO] Sonarr: Episode title is TBA, refreshing series metadata..."
  +-- POST /api/v3/command { name: "RefreshSeries", seriesId: <id> }
  +-- Poll command until complete (reuse Wait-SAImporterCommand, timeout: 2 min)
  +-- LOG: "[OK] Sonarr: Metadata refreshed, re-scanning..."
  +-- Re-run ManualImport scan
  +-- Re-run enrichment + filter (Steps 2-4)
  +-- If now importable -> continue to Step 6 (IMPORT)
  +-- If still TBA -> complete with warning + hint
```

**New function:** `Invoke-SAArrSeriesRefresh` in ImportArr.ps1

```
Parameters: AppType, Config, SeriesId
- POST /api/v3/command with { name: "RefreshSeries", seriesId: $SeriesId }
- Poll with Wait-SAImporterCommand (timeout: 2 minutes)
- Return success/failure
```

**When refresh does not resolve TBA:**

- Warning: `"Sonarr: 1 file skipped (Episode title TBA) - use -Rerun to retry later"`
- Console hint: `"Hint: Sonarr auto-accepts TBA titles after 48 hours. Use -Rerun to retry."`
- Email note: `"Sonarr: 1 file skipped (Episode title TBA)"`

**SeriesId extraction:** Already available from `$scanItems[0].series.id` (populated by ManualImport scan or queue enrichment).

**Radarr:** Not in scope. Radarr has `RefreshMovie` but TBA titles are rare for movies. Same pattern can be added later.

**MissingAbsoluteEpisodeNumber (anime):** Grouped under `tba` error type. Same refresh logic applies - refreshing series metadata may populate the absolute episode number.

## Files to Modify

| File | Change |
|---|---|
| `Private/ArrMetadata.ps1` | Add new patterns to `Get-SASimplifiedRejectionReason` |
| `Public/ImportArr.ps1` | Add `Invoke-SAArrSeriesRefresh`, TBA detection + refresh + retry in Step 5, prefix email exceptions with label |
| `Public/ImportArr.ps1` | Add new error types to `Get-SAErrorTypeFromRejection` |
| `Private/ImportResultParser.ps1` | Add hints for new error types (tba, disk-space, scene-mapping, etc.) |
| `Private/Constants.ps1` | Add `TbaRefreshTimeoutMinutes = 2` |

## Not in Scope

- Re-queue with delay (rejected - would require re-running full pipeline or making phases idempotent)
- Radarr RefreshMovie (rare case, can add later with same pattern)
- Sonarr "Episode Title Required" config changes (user's Sonarr setting, not Stagearr's concern)
