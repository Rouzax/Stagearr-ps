# RCA: ONE PIECE S02 Duplicate Downloads

**Date:** 2026-03-21
**Series:** ONE PIECE (2023) - Season 02 (8 episodes)
**Profile:** WEB-2160p (cutoffFormatScore: 1750)
**Status:** Resolved (current files: XEBEC, score 1800)

## Summary

ONE PIECE S02 was downloaded **5 separate times** between March 10-21, 2026. A combination of Recyclarr/Sonarr custom format gaps and a Stagearr season pack import issue caused repeated upgrade cycles and redundant imports.

## Timeline

| Date | Release | Quality | CF Score | What happened |
|------|---------|---------|----------|---------------|
| Mar 10 10:36 | BYNDR S02 (season pack) | 1080p | grabbed 1735, imported **-8275** | A -10000 CF penalty matched on import but not on grab, tanking the on-disk score |
| Mar 10 10:44 | BYNDR S02 (re-grab #1) | 1080p | -8275 | Ignored (same torrent hash still in client) |
| Mar 10 10:46 | BYNDR S02 (re-grab #2) | 1080p | 1725 | Sonarr grabbed again; this time imported correctly at 1725 |
| Mar 10 12:10 | Kitsune S02 (season pack) | 1080p | 1785 | Legit upgrade (1785 > 1725) |
| Mar 11 12:02 | **BiOMA S02** (season pack) | **2160p** | **660** | Quality upgrade (1080p -> 2160p), but BiOMA is not in any WEB Tier. Score 660 is far below cutoff (1750). Episodes stuck in perpetual "wanted" state. |
| Mar 11 12:20 | BiOMA (re-import #2) | 2160p | 660 | Same files re-imported by Stagearr (see Finding 3) |
| Mar 11 12:50 | BiOMA (re-import #3) | 2160p | 660 | Same files re-imported a third time |
| Mar 18 11:15 | Unknown 2160p | 2160p | - | 8x downloadIgnored |
| Mar 21 03:23 | **XEBEC S02** (individual eps) | 2160p | 1800 | Upgrade from BiOMA (660 -> 1800). Score now above cutoff. |
| Mar 21 04:03-08:15 | XEBEC imported | 2160p | 1800 | Final state. Loop should be over. |

**Total wasted downloads:** ~4 full season downloads (32 episode files) that were unnecessary.

## Root Cause Analysis

### Finding 1: BiOMA has no WEB Tier score (PRIMARY CAUSE)

BiOMA is not recognized by any TRaSH WEB Tier custom format (Tier 01, 02, 03, or WEB Scene). This means a BiOMA release only scores:

- NF: 75
- HDR: 500
- UHD Streaming Boost: 75
- Season Pack: 10
- **Total: 660**

Since the cutoff is 1750, any release scoring above 660 would be grabbed as an upgrade. This kept the episodes in a permanent upgrade-wanted state for 10 days until XEBEC (Tier 02, score 1800) appeared.

**Why this matters:** Sonarr correctly detected BiOMA as a quality upgrade (1080p -> 2160p) and grabbed it. The quality cutoff (WEB 2160p) was met, but the FORMAT score cutoff (1750) was not. Sonarr's upgrade logic requires BOTH to be satisfied, so it kept searching.

### Finding 2: BYNDR import score flip (-8275 vs 1735)

The BYNDR season pack was grabbed with score 1735 but imported with score **-8275**. The difference is exactly -10000, meaning a penalty CF (likely `x265 (no HDR/DV)` or `German DL`) matched during import that did not match during the grab evaluation.

This happened for the first two import rounds but not the third, suggesting a transient evaluation issue -- possibly related to how Sonarr re-evaluates custom formats on the actual file vs the release name.

Score breakdown:
- **Grab (release name):** WEB Tier 02 (1650) + NF (75) + Season Pack (10) = **1735**
- **Import round 1-2:** 1725 + (-10000 penalty) = **-8275**
- **Import round 3:** WEB Tier 02 (1650) + NF (75) = **1725** (correct, no penalty)

This caused the same BYNDR release to be grabbed 3 times on the same day.

### Finding 3: Stagearr triple-imports season packs (STAGEARR ISSUE)

The BiOMA season pack was imported **3 separate times** within 30 minutes:

| Time | Download ID | Source |
|------|-------------|--------|
| 12:20 | AA30DCE3AF66 | Sonarr's download client handler (qBittorrent completion) |
| 12:29 | (none) | Stagearr ManualImport API call |
| 12:50 | (none) | Stagearr ManualImport API call (again) |

The imports without a `downloadId` are from Stagearr's ManualImport API. Each round deleted the previously imported files and re-imported the same content. While not the cause of the upgrade loop, this tripled the I/O and processing for every season pack.

**Likely cause:** Stagearr processes episode files from a season pack individually through its pipeline (subtitle extraction, stripping, etc.). Each processed episode may trigger a ManualImport call that scans the staging folder and picks up OTHER already-processed episode files, causing batch re-imports. Alternatively, Sonarr's own download handler races with Stagearr's import, both trying to import the same completed download.

## Current State

| Episode | Quality | Group | CF Score | CFs Matched |
|---------|---------|-------|----------|-------------|
| S02E01 | WEBDL-2160p | XEBEC | 1805 | NF, Repack/Proper, UHD Streaming Boost, WEB Tier 02 |
| S02E02-E08 | WEBDL-2160p | XEBEC | 1800 | NF, UHD Streaming Boost, WEB Tier 02 |

All scores are above the cutoff of 1750. **The upgrade loop should be resolved.**

## Recommendations

### Sonarr/Recyclarr Configuration

1. **Set `minFormatScore` to prevent low-scoring grabs**

   In the WEB-2160p quality profile, set `minFormatScore` to a value like 1000 or 1500. This prevents Sonarr from grabbing releases like BiOMA that technically match on quality but have an abysmal CF score, which then traps the episode below cutoff.

   In recyclarr `sonarr.yml`:
   ```yaml
   quality_profiles:
     - trash_id: d1498e7d189fbe6c7110ceaabb7473e6  # WEB-2160p
       min_format_score: 1000  # <-- add this
   ```

2. **Monitor for unknown release groups**

   Consider whether groups not in any WEB Tier should be allowed at all. The `LQ` and `LQ (Release Title)` CFs block known bad groups, but BiOMA slipped through as "not bad, just unranked."

### Stagearr (already fixed)

3. **Season pack triple-import -- RESOLVED in v2.0.6 (a7f15ac, 2026-03-16)**

   The BiOMA triple-import on March 11 was caused by a missing `downloadId` on ManualImport file objects. Without per-file `downloadId`, Sonarr treated Stagearr's imports as "untracked" -- no `DownloadCompletedEvent` fired, the torrent stayed in the queue, and Sonarr's own download handler also tried to import the same files. This was fixed in commit `a7f15ac` which sends `downloadId` per-file, ensuring Sonarr associates the import with the correct download client entry.

   Follow-up fixes: `42c6ded` (Radarr command-level downloadId), `e863cc3` (NRE recovery), `def218c` (Radarr per-file downloadId), `51edc9d` (post-import count verification).

## Appendix: Score Calculation Reference

WEB-2160p profile active custom formats with positive scores:

| Custom Format | Score |
|---------------|-------|
| WEB Tier 01 | 1700 |
| WEB Tier 02 | 1650 |
| WEB Tier 03 / WEB Scene | 1600 |
| HDR | 500 |
| Streaming services (NF, AMZN, etc.) | 75 each |
| HD/UHD Streaming Boost | 75 |
| Season Pack | 10 |
| Repack/Proper | 5 |

Groups by tier:
- **Tier 01:** FLUX (score ~1775-1850 depending on service+HDR)
- **Tier 02:** XEBEC, BYNDR, Kitsune, playWEB, NTb (score ~1725-1810)
- **Not in any tier:** BiOMA (score ~650-660)
