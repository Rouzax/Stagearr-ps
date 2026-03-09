# Queue-Based Scan Enrichment

## Problem

When release names contain typos (e.g., "Vanised" instead of "Vanished"), the *arr ManualImport scan fails to match the series/movie and rejects all files as "Unknown Series". This happens despite the *arr app already knowing which series the torrent belongs to (from the original grab).

## Solution

After the ManualImport scan, query the *arr queue API using the torrent hash (`DownloadId`) to retrieve the correct series/movie and episode data. Inject that data into scan results that are missing it. This runs on every import (not just failures), making it a proactive enrichment rather than a fallback.

## Design

### New function: `Invoke-SAArrQueueEnrichment`

**File:** `Private/QueueEnrichment.ps1`

**Signature:**
```powershell
Invoke-SAArrQueueEnrichment -AppType <Radarr|Sonarr> -Config <hashtable> -ScanResults <array> -DownloadId <string>
```

**Logic:**
1. If no `DownloadId`, return scan results unchanged
2. `GET /api/v3/queue?downloadId={hash}` to get queue record(s)
3. Extract media identity from queue:
   - Sonarr: `seriesId`, `series` object, `episode` objects
   - Radarr: `movieId`, `movie` object
4. For each scan result missing `series`/`movie` data (or with "Unknown Series/Movie" rejection):
   - Inject the series/movie identity from queue
   - Keep episode matching from scan if available (filename episode parsing works even when series matching fails)
   - Remove "Unknown Series/Movie" rejection entries
5. Return enriched scan results

### Integration point

In `Invoke-SAArrImport` (ImportArr.ps1), between Step 1 (SCAN) and Step 2 (EXTRACT):

```powershell
# STEP 1.5: ENRICH - Use queue data to fill missing series/movie info
$scanItems = Invoke-SAArrQueueEnrichment -AppType $AppType -Config $Config `
    -ScanResults $scanItems -DownloadId $DownloadId
```

### What stays the same

- Scan still runs (provides quality, language, file paths, episode parsing)
- Filter still runs (catches legitimate rejections like quality cutoff)
- Execute runs as-is (already handles seriesId/movieId from scan results)
- Metadata extraction benefits (more likely to have series/movie data)

### Edge cases

- **No queue record** (manually added torrent): no enrichment, current behavior preserved
- **Queue has season-level info only**: inject seriesId, keep scan's episode-level parsing
- **API failure**: log warning, return scan results unchanged (non-breaking)

## Scope

- Works for both Sonarr and Radarr
- Single new file (`Private/QueueEnrichment.ps1`)
- Small insertion in `Invoke-SAArrImport`
- Module manifest and loader updated to include new file
