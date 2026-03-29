# RCA: Fake EXE Torrents from IPTorrents

**Date:** 2026-03-21
**Provider:** IPTorrents (via Prowlarr)
**Source:** RSS feed
**Status:** Resolved (dangerous file detection added in v2.3.0)

## Summary

4 fake torrents uploaded to IPTorrents contained .exe files (probable malware) disguised as TV episodes using legitimate scene group names. Sonarr grabbed them via RSS, Stagearr correctly identified "No media files found" but had no mechanism to report the failure back to Sonarr or blocklist the releases.

## Affected Downloads

| Release | Fake Group | IPT Torrent ID | Size | CF Score |
|---------|-----------|----------------|------|----------|
| Shrinking S03E09 1080p ATVP WEB-DL DDP5 1 Atmos H 264-playWEB.exe | playWEB | 7289126 | 1.08 GB | 1725 |
| Paradise 2025 S02E08 1080p WEB h264-ETHEL.exe | ETHEL | 7289131 | 1.18 GB | 0 |
| The Pitt S02E12 1080p WEB h264-ETHEL.exe | ETHEL | (sequential) | 1.18 GB | 0 |
| Dark Winds S04E07 1080p AMZN WEB-DL DDP5 1 H 264-RAW.exe | RAW | 7289171 | 1.18 GB | 75 |

All torrents were published within ~10 minutes of each other (10:01-10:10 UTC), with sequential IPT IDs, indicating a coordinated upload.

## Root Cause

### Why Sonarr grabbed them

Sonarr evaluates release **names**, not file contents. The fake torrents used:
- Perfect scene naming conventions (SxxExx, quality tags, codec info)
- Real release group names (playWEB is WEB Tier 02, scoring 1725)
- Realistic file sizes (~1 GB, plausible for 1080p episodes)

Sonarr has no mechanism to inspect file contents before downloading. The releases passed all custom format and quality checks.

### Why Stagearr didn't handle it (before fix)

1. Stagearr correctly detected "No media files found" during staging
2. But it had **no feedback mechanism** to report failures to Sonarr/Radarr
3. Downloads remained stuck in Sonarr queue as `importPending` with warnings
4. No blocklist entry was created, leaving the releases eligible for re-grab

## Resolution

### Stagearr changes (v2.3.0)

Added dangerous file detection and blocklist reporting:

1. **`Test-SADangerousDownload`** - Scans source path for executable/script file extensions. Flags downloads where ALL files are dangerous (no media mixed in). Only applies to TV/Movie labels; passthrough jobs are excluded.

2. **`Remove-SAArrQueueItem`** - Calls `DELETE /api/v3/queue/{id}?removeFromClient=true&blocklist=true&skipRedownload=true` to remove the download from qBittorrent, add to the Sonarr/Radarr blocklist, and prevent re-grabbing.

3. **Integration in `Invoke-SAStandardJob`** - Safety check runs after queue lookup but before video processing. On detection: logs security error, blocklists, sends failure email, aborts job.

Dangerous extensions detected: `.exe`, `.msi`, `.bat`, `.cmd`, `.scr`, `.com`, `.pif`, `.vbs`, `.vbe`, `.js`, `.jse`, `.wsf`, `.wsh`, `.lnk`

### Manual actions taken

- Reported fake torrents to IPTorrents
- Manually removed stuck queue items from Sonarr

## Recommendations

1. **Monitor IPTorrents** for similar fake uploads targeting other series
2. **Consider minimum seeder/age thresholds** in Prowlarr to avoid grabbing brand-new uploads immediately (though this delays legitimate releases too)
3. **Report fake groups to TRaSH Guides** if the pattern continues (for potential LQ custom format inclusion)
