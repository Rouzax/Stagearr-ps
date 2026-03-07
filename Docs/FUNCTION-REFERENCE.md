# Stagearr Function Reference

> Quick reference for contributors. Check here before implementing new functionality.

---

## Where to Start Reading

| File | Purpose |
|------|---------|
| `Stagearr.ps1` | CLI entrypoint (qBittorrent hook, worker/status/recover) |
| `Public/JobProcessor.ps1` | `Invoke-SAJobProcessing` orchestrates the whole pipeline |
| `Private/Output/OutputEvent.ps1` | Event-based output contract (`Write-SAOutcome`, etc.) |
| `config-sample.toml` | All config knobs and expected structure |

---

## Repo Structure

```
Stagearr.ps1                    # CLI entrypoint
config-sample.toml                   # Sample configuration
Modules/Stagearr.Core/
├── Stagearr.Core.psd1          # Module manifest
├── Stagearr.Core.psm1          # Module loader
├── Private/                         # Internal helpers
│   ├── Output/                      # Output/rendering subsystem
│   │   ├── ConsoleRenderer.ps1      # Console output with colors/markers
│   │   ├── EmailHelpers.ps1         # Email display helpers, color palette
│   │   ├── EmailRenderer.ps1        # Email state management, orchestration
│   │   ├── EmailSections.ps1        # Email HTML section builders
│   │   ├── EmailSubject.ps1         # Email subject line generation
│   │   ├── FileLogRenderer.ps1      # Plain-text log files
│   │   └── OutputEvent.ps1          # Central event dispatcher
│   ├── Config.ps1                   # Load, merge, validate config
│   ├── Constants.ps1                # Centralized constants
│   ├── Context.ps1                  # Job context, tool versions
│   ├── EpisodeFormatting.ps1        # Episode number formatting and grouping
│   ├── ErrorHandling.ps1            # User-friendly error messages
│   ├── FileIO.ps1                   # UTF-8 file operations, atomic writes
│   ├── Formatting.ps1               # Size, duration, pluralization formatting
│   ├── Http.ps1                     # HTTP client with retry
│   ├── ImportResultParser.ps1       # Parse importer API responses
│   ├── ImportUtility.ps1            # URL building, path translation
│   ├── ArrMetadata.ps1              # *arr metadata extraction (ManualImport)
│   ├── ConfigSync.ps1               # Config sync detection and merge
│   ├── Language.ps1                 # ISO 639 language codes
│   ├── MediaDisplay.ps1             # Source/service/HDR display name formatting, quality strings
│   ├── MediaParsing.ps1             # Media filename parsing, release info
│   ├── MkvAnalysis.ps1              # Video analysis, hashing
│   ├── Omdb.ps1                     # OMDb API client (metadata, poster download)
│   ├── PathSecurity.ps1             # Path validation, traversal prevention
│   ├── Process.ps1                  # External process execution
│   └── Utility.ps1                  # Hash, platform detection, misc
└── Public/                          # Exported API
    ├── Import.ps1                   # Main import dispatcher
    ├── ImportArr.ps1                # Radarr/Sonarr API integration
    ├── ImportMedusa.ps1             # Medusa API integration
    ├── JobProcessor.ps1             # Job orchestration
    ├── Lock.ps1                     # Global mutex
    ├── Notification.ps1             # Email sending
    ├── OpenSubtitles.ps1            # OpenSubtitles API integration
    ├── Queue.ps1                    # Job queue CRUD
    ├── RarExtraction.ps1            # RAR extraction with security validation
    ├── Staging.ps1                  # Staging folder operations
    ├── SubtitleProcessing.ps1       # Subtitle processing and analysis
    └── Video.ps1                    # MKV remux, MP4 conversion
```

**Total: ~255 functions across 38 source files**

---

## Module Load Order

`Stagearr.Core.psm1` dot-sources files in this order. **If you add a new file, add it here or it won't load.**

**Private (loaded first)** — 27 files including Output/ subfolder

1. Constants.ps1
2. Formatting.ps1
3. PathSecurity.ps1
4. FileIO.ps1
5. EpisodeFormatting.ps1
6. MediaParsing.ps1
7. MediaDisplay.ps1
8. Utility.ps1
9. Output/ConsoleRenderer.ps1
10. Output/FileLogRenderer.ps1
11. Output/EmailHelpers.ps1
12. Output/EmailRenderer.ps1
13. Output/EmailSections.ps1
14. Output/EmailSubject.ps1
15. Output/OutputEvent.ps1
16. Language.ps1
17. Process.ps1
18. ErrorHandling.ps1
19. Http.ps1
20. Omdb.ps1
21. ConfigSync.ps1
22. Config.ps1
23. Context.ps1
24. MkvAnalysis.ps1
25. ImportUtility.ps1
26. ImportResultParser.ps1
27. ArrMetadata.ps1

**Public (loaded after Private)** — 12 files

1. Lock.ps1
2. Queue.ps1
3. Notification.ps1
4. Staging.ps1
5. RarExtraction.ps1
6. Video.ps1
7. OpenSubtitles.ps1
8. SubtitleProcessing.ps1
9. ImportArr.ps1
10. ImportMedusa.ps1
11. Import.ps1
12. JobProcessor.ps1

---

## Runtime Flow

### Entry Modes (`Stagearr.ps1`)

| Mode | What it does |
|------|--------------|
| Normal | Validate input → `Add-SAJob` (queue job) |
| `-Worker` | `Start-SAWorker` → process pending jobs |
| `-Status` | Show queue counts, running job details (phase/activity/elapsed), completed/failed history |
| `-Requeue` | Move stale running jobs back to pending |
| `-SyncConfig` | Sync config.toml with config-sample.toml (add/remove settings) |

### Job Pipeline (`Invoke-SAJobProcessing`)

```
1. Initialize    → Initialize-SAOutputSystem, New-SAContext
2. Stage         → Copy/extract to staging folder
3. Video         → Unrar, remux, extract/strip subtitles
4. Subtitles     → OpenSubtitles download + SubtitleEdit cleanup
5. Import        → Send to Radarr/Sonarr/Medusa
6. Notify        → Save log file + send email
```

---

## Before You Write New Code

**Check if it already exists:**

| If you need to... | Use this | File |
|-------------------|----------|------|
| Make HTTP request | `Invoke-SAWebRequest` | Http.ps1 |
| Fetch OMDb metadata | `Get-SAOmdbMetadata` | Omdb.ps1 |
| Extract *arr metadata | `ConvertTo-SAArrMetadata` | ArrMetadata.ps1 |
| Get *arr metadata with poster | `Get-SAArrMetadataFromScan` | ArrMetadata.ps1 |
| Filter importable files | `Get-SAImportableFiles` | ArrMetadata.ps1 |
| Summarize rejections | `Get-SARejectionSummary` | ArrMetadata.ps1 |
| Run external tool | `Invoke-SAProcess` | Process.ps1 |
| Run tool with retry | `Invoke-SAProcessWithRetry` | ErrorHandling.ps1 |
| Format file size | `Format-SASize` | Formatting.ps1 |
| Format duration | `Format-SADuration` | Formatting.ps1 |
| Get plural form | `Get-SAPluralForm` | Formatting.ps1 |
| Get timestamp | `Get-SATimestamp` | Formatting.ps1 |
| Normalize language code | `ConvertTo-SALanguageCode` | Language.ps1 |
| Get language info | `Get-SALanguageInfo` | Language.ps1 |
| Sanitize filename | `Get-SASafeName` | PathSecurity.ps1 |
| Validate path security | `Assert-SAPathUnderRoot` | PathSecurity.ps1 |
| Detect sample files | `Test-SASamplePath` | PathSecurity.ps1 |
| Create directory | `New-SADirectory` | FileIO.ps1 |
| Write UTF-8 file | `Write-SAFileUtf8NoBom` | FileIO.ps1 |
| Atomic file write | `Write-SAFileAtomicUtf8NoBom` | FileIO.ps1 |
| Write lines to file | `Write-SAFileLinesUtf8NoBom` | FileIO.ps1 |
| Group consecutive episodes | `Group-SAConsecutiveEpisodes` | EpisodeFormatting.ps1 |
| Format episode range | `Format-SAEpisodeRange` | EpisodeFormatting.ps1 |
| Format episode list | `Format-SAEpisodeList` | EpisodeFormatting.ps1 |
| Format episode outcome | `Format-SAEpisodeOutcome` | EpisodeFormatting.ps1 |
| Parse media filename | `Get-SAMediaInfo` | MediaParsing.ps1 |
| Parse release name | `Get-SAReleaseInfo` | MediaParsing.ps1 |
| Parse filename to episode info | `Get-SAFileEpisodeInfo` | MediaParsing.ps1 |
| Compute video hash | `Get-SAVideoHash` | MkvAnalysis.ps1 |
| Analyze MKV tracks | `Get-SAMkvInfo` | MkvAnalysis.ps1 |
| Log to console | `Write-SAOutcome`, `Write-SAProgress` | Output/OutputEvent.ps1 |
| Log verbose | `Write-SAVerbose` | Output/OutputEvent.ps1 |
| Add email warning | `Add-SAEmailException` | Output/EmailRenderer.ps1 |
| Format episode note for email | `Format-SAImportEpisodeNote` | JobProcessor.ps1 |
| Extract Medusa file details | `Get-SAMedusaFileDetails` | ImportResultParser.ps1 |
| Write episode-level Medusa result | `Write-SAMedusaEpisodeOutcome` | ImportMedusa.ps1 |
| Extract RAR archive safely | `Start-SAUnrar` | RarExtraction.ps1 |
| Validate RAR entries | `Test-SARarEntriesSafe` | RarExtraction.ps1 |
| Get OpenSubtitles token | `Get-SAOpenSubtitlesToken` | OpenSubtitles.ps1 |
| Download from OpenSubtitles | `Start-SAOpenSubtitlesDownload` | OpenSubtitles.ps1 |
| Clean subtitles with SubtitleEdit | `Start-SASubtitleCleanup` | SubtitleProcessing.ps1 |
| Check if config needs sync | `Test-SAConfigSync` | ConfigSync.ps1 |
| Sync config with sample | `Sync-SAConfig` | ConfigSync.ps1 |
| Compare config schemas | `Compare-SAConfigSchema` | ConfigSync.ps1 |
| Generate config sync report | `Get-SAConfigSyncReport` | ConfigSync.ps1 |

---

## Exported Functions (Public API)

### Output System

| Function | Purpose | File |
|----------|---------|------|
| `Initialize-SAOutputSystem` | Init output for new job | Output/OutputEvent.ps1 |
| `Reset-SAOutputState` | Reset between jobs | Output/OutputEvent.ps1 |
| `Write-SAPhaseHeader` | Section header (Staging/Import/etc) | Output/OutputEvent.ps1 |
| `Write-SAOutcome` | Result with marker (✓/!/✗) | Output/OutputEvent.ps1 |
| `Write-SAProgress` | Progress info (no marker) | Output/OutputEvent.ps1 |
| `Write-SAVerbose` | Verbose-level output | Output/OutputEvent.ps1 |
| `Write-SAPollingStatus` | Rate-limited polling status | Output/OutputEvent.ps1 |
| `Get-SAJobDuration` | Elapsed time since job start | Output/OutputEvent.ps1 |
| `Write-SABanner` | Stagearr title banner | Output/ConsoleRenderer.ps1 |
| `Write-SAKeyValue` | Key-value pair output | Output/ConsoleRenderer.ps1 |
| `Set-SAEmailSummary` | Set email data directly | Output/EmailRenderer.ps1 |
| `Add-SAEmailException` | Add warning to email | Output/EmailRenderer.ps1 |
| `Set-SAEmailLogPath` | Set log path for email | Output/EmailRenderer.ps1 |
| `ConvertTo-SAEmailHtml` | Generate complete HTML | Output/EmailRenderer.ps1 |
| `Save-SAFileLog` | Save log to disk | Output/FileLogRenderer.ps1 |

### Email Subject Template Engine

Functions for generating configurable email subjects with presets and custom templates.

| Function | Purpose | File |
|----------|---------|------|
| `Get-SASourceDisplayName` | Convert source to compact display (UHD/WEB/Remux) | MediaDisplay.ps1 |
| `Get-SAServiceDisplayName` | Convert streaming service to abbreviation (NF/AMZN) | MediaDisplay.ps1 |
| `Get-SAHdrDisplayName` | Convert HDR tags to display name (Dolby Vision/HDR10+) | MediaDisplay.ps1 |
| `Get-SAQualityDisplayString` | Build bullet-separated quality string for email | MediaDisplay.ps1 |
| `Get-SAQualityLogString` | Build space-separated quality string for logs | MediaDisplay.ps1 |
| `Add-SAReleaseDisplayInfo` | Enrich ReleaseInfo with all display values | MediaDisplay.ps1 |
| `Get-SASubjectPresetTemplate` | Get template string for preset style | Output/EmailSubject.ps1 |
| `Format-SAEmailSubjectCleanup` | Clean up artifacts from empty placeholders | Output/EmailSubject.ps1 |
| `Format-SAEmailSubject` | Main template engine with placeholder substitution | Output/EmailSubject.ps1 |
| `Build-SASubjectPlaceholders` | Build hashtable from release metadata | Output/EmailSubject.ps1 |
| `Get-SAEmailSubject` | Generate subject using style/template config | Output/EmailSubject.ps1 |

**Preset Styles:**

| Preset | Template | Example |
|--------|----------|---------|
| `detailed` | `{result}{label}: {name} [{resolution} {source}-{group}]` | `Movie: Inception (2010) [2160p UHD-GROUP]` |
| `quality` | `{result}{label}: {name} [{resolution}]` | `Movie: Inception (2010) [2160p]` |
| `source` | `{result}{label}: {name} [{source}-{group}]` | `Movie: Inception (2010) [BluRay-GROUP]` |
| `group` | `{result}{label}: {name} [-{group}]` | `Movie: Inception (2010) [NTb]` |
| `hash` | `{result}{label}: {name} [{hash4}]` | `Movie: Inception (2010) [a1b2]` |
| `none` | `{result}{label}: {name}` | `Movie: Inception (2010)` |
| `custom` | *(user-defined via subjectTemplate)* | *(varies)* |

**Placeholders:**

| Placeholder | Description | Example Values |
|-------------|-------------|----------------|
| `{result}` | Status prefix (empty for success/warning) | `Failed: `, `Skipped: `, `` |
| `{label}` | Download label | `Movie`, `TV`, `software` |
| `{name}` | Friendly name | `Inception (2010)`, `Stranger Things S05` |
| `{resolution}` | Screen size | `2160p`, `1080p`, `720p` |
| `{source}` | Source type (Remux takes precedence) | `WEB`, `BluRay`, `Remux`, `UHD` |
| `{group}` | Release group | `NTb`, `CiNEPHiLES`, `SPARKS` |
| `{service}` | Streaming service abbreviation | `NF`, `AMZN`, `HMAX`, `DSNP` |
| `{hash4}` | First 4 chars of torrent hash | `a1b2`, `xyz7` |

### OMDb Integration

Functions for enriching email notifications with movie/TV metadata from OMDb API.

| Function | Purpose | File |
|----------|---------|------|
| `Get-SAOmdbMetadata` | Main entry — fetches and normalizes OMDb data | Omdb.ps1 |
| `Invoke-SAOmdbRequest` | HTTP wrapper with timeout/error handling | Omdb.ps1 |
| `Get-SAOmdbPosterData` | Downloads poster, returns structured data for CID attachment | Omdb.ps1 |
| `ConvertTo-SAOmdbDisplayData` | Extracts display-ready data from API response (pure) | Omdb.ps1 |

**Return Structure (from `Get-SAOmdbMetadata`):**

| Field | Type | Description |
|-------|------|-------------|
| `Title` | string | Movie/show title |
| `Year` | string | Release year |
| `ImdbId` | string | IMDb identifier (e.g., `tt1375666`) |
| `ImdbRating` | string | IMDb score (e.g., `8.8`) |
| `RottenTomatoes` | string | RT score (e.g., `87%`) or `$null` |
| `Metacritic` | string | Metacritic score (e.g., `74`) or `$null` |
| `Genre` | string | Comma-separated genres |
| `Runtime` | string | Duration (e.g., `148 min`) |
| `Plot` | string | Synopsis (if enabled) or `$null` |
| `PosterData` | hashtable | Structured poster data for CID attachment (see below) |
| `PosterBase64` | string | *(Deprecated)* Data URI for embedding or `$null` |
| `Type` | string | `movie` or `series` |
| `TotalSeasons` | string | Season count for series or `$null` |

**PosterData Structure (from `Get-SAOmdbPosterData`):**

| Field | Type | Description |
|-------|------|-------------|
| `Bytes` | byte[] | Raw image bytes for attachment |
| `MimeType` | string | MIME type (e.g., `image/jpeg`, `image/png`) |
| `ContentId` | string | Unique CID for email reference (e.g., `poster-a1b2c3d4`) |

> **Note:** `PosterBase64` is deprecated and will be removed in a future version.
> Use `PosterData` with CID inline attachments for email rendering.

**Email Rendering Behavior:**

When `PosterData` is present with a valid `ContentId`, the email HTML renders:
```html
<img src="cid:poster-abc12345" ... />
```

This requires the image to be attached as an inline attachment (see `Send-SAEmail`).
If `PosterData` is null but `PosterBase64` exists, falls back to the deprecated data URI format.

**Config Structure:**

```json
{
  "omdb": {
    "enabled": false,
    "apiKey": "",
    "timeoutSeconds": 5,
    "poster": { "enabled": true },
    "display": {
      "plot": false,
      "plotMaxLength": 150
    }
  }
}
```

### Configuration

| Function | Purpose | File |
|----------|---------|------|
| `Read-SAConfig` | Load config from JSON | Config.ps1 |
| `Test-SAFeatureEnabled` | Check if optional feature is enabled | Config.ps1 |
| `Sync-SAConfig` | Sync user config with sample (add/remove settings) | ConfigSync.ps1 |
| `Test-SAConfigSync` | Check if config needs synchronization | ConfigSync.ps1 |
| `Get-SAConfigSyncReport` | Generate detailed sync report | ConfigSync.ps1 |
| `Compare-SAConfigSchema` | Find missing/extra keys between configs | ConfigSync.ps1 |

### Feature Flags

Stagearr supports optional processing features that can be enabled/disabled via `config.toml`. Use `Test-SAFeatureEnabled` to check feature status.

| Feature | Config Path | Default | Tools Required |
|---------|-------------|---------|----------------|
| Subtitle Extraction | `subtitles.extraction.enabled` | `true` | mkvextract |
| Subtitle Stripping | `subtitles.stripping.enabled` | `true` | mkvmerge |
| SubtitleEdit Cleanup | `subtitles.cleanup.enabled` | `true` | subtitleEdit |
| OpenSubtitles Download | `subtitles.openSubtitles.enabled` | `false` | (API only) |
| MP4→MKV Remux | `video.mp4Remux.enabled` | `true` | mkvmerge |
| OMDb Enrichment | `omdb.enabled` | `false` | (API only) |

**Behavior when disabled:**
- **SubtitleExtraction**: Subtitle tracks remain in MKV only (no SRT files created)
- **SubtitleStripping**: All original subtitle tracks preserved in output
- **SubtitleCleanup**: SRT files not processed by SubtitleEdit
- **OpenSubtitles**: No API calls, no hash computation (saves I/O)
- **Mp4Remux**: MP4 files copied as-is without container conversion
- **OMDb Enrichment**: Emails render without poster, ratings, or metadata (default layout)

### Email Metadata Source

Controls the source for email metadata enrichment (poster, ratings, etc.).

| Config Path | Options | Default | Description |
|-------------|---------|---------|-------------|
| `notifications.email.metadata.source` | `auto`, `omdb`, `none` | `auto` | Metadata source priority |
| `notifications.email.metadata.poster.size` | `w92`, `w185`, `w500`, `original` | `w185` | TMDb poster size |

**Source options:**
- **auto** (default): Uses *arr metadata when available (Radarr/Sonarr ManualImport), falls back to OMDb for Medusa or when *arr metadata unavailable
- **omdb**: Always uses OMDb API (requires `omdb.enabled` and `omdb.apiKey`)
- **none**: Disables metadata enrichment entirely

**Note**: The `omdb.poster.enabled` setting controls whether posters are displayed (both arr and OMDb sources). The `notifications.email.metadata.poster.size` controls the poster resolution for arr metadata.

### Import Mode

Controls how files are handled during import to Radarr/Sonarr.

| Config Path | Options | Default | Description |
|-------------|---------|---------|-------------|
| `importers.radarr.importMode` | `move`, `copy` | `move` | File handling during Radarr import |
| `importers.sonarr.importMode` | `move`, `copy` | `move` | File handling during Sonarr import |

**Mode options:**
- **move** (default): Moves files from staging to library, deleting originals
- **copy**: Copies files to library, preserving originals in staging

### Processing Configuration

| Config Path | Type | Default | Description |
|-------------|------|---------|-------------|
| `processing.tvImporter` | string | `Medusa` | Default TV importer (`Medusa` or `Sonarr`) |
| `processing.cleanupStaging` | bool | `true` | Remove staging folder after processing |
| `processing.staleLockMinutes` | int | `15` | Lock considered stale after this many minutes |

**Behavior notes:**
- **cleanupStaging**: Set to `false` to preserve staging folder for debugging. Can also be overridden per-job with `-NoCleanup` switch.
- **staleLockMinutes**: Worker lock is released if held longer than this, allowing recovery from crashes/hangs.

### Label Configuration

Multiple labels can be configured to route downloads to the correct importer.

| Config Path | Type | Default | Description |
|-------------|------|---------|-------------|
| `labels.tv` | string | `TV` | Primary TV label |
| `labels.movie` | string | `Movie` | Primary movie label |
| `labels.skip` | string | `NoProcess` | Label to skip processing entirely |
| `labels.tvLabels` | array | `[]` | Additional labels treated as TV |
| `labels.movieLabels` | array | `[]` | Additional labels treated as movies |

**Example:**
```json
{
  "labels": {
    "tv": "TV",
    "movie": "Movie",
    "skip": "Manual",
    "tvLabels": ["sonarr", "series", "shows"],
    "movieLabels": ["radarr", "films"]
  }
}
```

### Queue Operations

| Function | Purpose | File |
|----------|---------|------|
| `Add-SAJob` | Enqueue new job | Queue.ps1 |
| `Get-SAJob` | Get job by ID | Queue.ps1 |
| `Get-SAJobs` | Get jobs by state | Queue.ps1 |
| `Remove-SAJob` | Remove job | Queue.ps1 |
| `Start-SAWorker` | Process pending jobs | Queue.ps1 |
| `Restore-SAOrphanedJobs` | Restore crashed jobs | Queue.ps1 |
| `Update-SAJobProgress` | Update running job's phase/activity for `-Status` | Queue.ps1 |

### Job Processing

| Function | Purpose | File |
|----------|---------|------|
| `Invoke-SAJobProcessing` | **Main entry** - full pipeline | JobProcessor.ps1 |

### Lock Management

| Function | Purpose | File |
|----------|---------|------|
| `Get-SAGlobalLock` | Acquire worker lock | Lock.ps1 |
| `Unlock-SAGlobalLock` | Release lock | Lock.ps1 |
| `Test-SAGlobalLock` | Check if locked | Lock.ps1 |
| `Get-SAGlobalLockInfo` | Get lock holder info | Lock.ps1 |

### RAR Extraction

| Function | Purpose | File |
|----------|---------|------|
| `Test-SARarEntriesSafe` | Validate archive entries against path traversal | RarExtraction.ps1 |
| `Start-SAUnrar` | Extract RAR archive safely | RarExtraction.ps1 |

### Video Processing

| Function | Purpose | File |
|----------|---------|------|
| `Invoke-SAVideoProcessing` | **Main entry** - video pipeline | Video.ps1 |
| `Start-SAMkvRemux` | Remux MKV selectively | Video.ps1 |
| `Start-SARemuxMP4` | Convert MP4 to MKV | Video.ps1 |
| `Start-SAExtractSubtitles` | Extract subtitle tracks from MKV | Video.ps1 |
| `Invoke-SAPassthroughProcessing` | Handle non-video labels | Video.ps1 |

### OpenSubtitles API

| Function | Purpose | File |
|----------|---------|------|
| `Get-SAOpenSubtitlesToken` | Get/refresh API token | OpenSubtitles.ps1 |
| `Search-SAOpenSubtitles` | Search for subtitle matches | OpenSubtitles.ps1 |
| `Get-SAOpenSubtitlesDownload` | Download individual subtitle | OpenSubtitles.ps1 |
| `Start-SAOpenSubtitlesDownload` | **Main entry** - download subtitles | OpenSubtitles.ps1 |

### Subtitle Processing

| Function | Purpose | File |
|----------|---------|------|
| `Invoke-SASubtitleProcessing` | **Main entry** - subtitle pipeline | SubtitleProcessing.ps1 |
| `Start-SASubtitleCleanup` | Clean SRTs with SubtitleEdit | SubtitleProcessing.ps1 |
| `Copy-SAExternalSubtitles` | Copy external SRT files | SubtitleProcessing.ps1 |
| `Reset-SASubtitlesState` | Clear OpenSubtitles token cache | SubtitleProcessing.ps1 |

### Import (Media Servers)

| Function | Purpose | File |
|----------|---------|------|
| `Invoke-SAImport` | **Main dispatcher** - route to importer | Import.ps1 |
| `Reset-SAImportState` | Reset state between jobs | Import.ps1 |
| `Invoke-SAArrImport` | Generic *arr import using ManualImport flow, returns ArrMetadata | ImportArr.ps1 |
| `Test-SAArrConnection` | Generic *arr connection test | ImportArr.ps1 |
| `Get-SAArrRecentErrors` | Generic *arr error log fetch | ImportArr.ps1 |
| `Invoke-SAArrManualImportScan` | Scan folder with ManualImport API, returns metadata | ImportArr.ps1 |
| `Invoke-SAArrManualImportExecute` | Execute import for specific files from scan | ImportArr.ps1 |
| `Get-SAErrorTypeFromRejection` | Map rejection reasons to error types for hints | ImportArr.ps1 |
| `Invoke-SARadarrImport` | Radarr import (wrapper) | ImportArr.ps1 |
| `Invoke-SASonarrImport` | Sonarr import (wrapper) | ImportArr.ps1 |
| `Invoke-SARadarrManualImportScan` | Radarr ManualImport scan (wrapper) | ImportArr.ps1 |
| `Invoke-SARadarrManualImportExecute` | Radarr ManualImport execute (wrapper) | ImportArr.ps1 |
| `Invoke-SASonarrManualImportScan` | Sonarr ManualImport scan (wrapper) | ImportArr.ps1 |
| `Invoke-SASonarrManualImportExecute` | Sonarr ManualImport execute (wrapper) | ImportArr.ps1 |
| `Test-SARadarrConnection` | Test Radarr API (wrapper) | ImportArr.ps1 |
| `Test-SASonarrConnection` | Test Sonarr API (wrapper) | ImportArr.ps1 |
| `Get-SARadarrRecentErrors` | Radarr errors (wrapper) | ImportArr.ps1 |
| `Get-SASonarrRecentErrors` | Sonarr errors (wrapper) | ImportArr.ps1 |
| `Invoke-SAMedusaImport` | Trigger Medusa import | ImportMedusa.ps1 |
| `Test-SAMedusaConnection` | Test Medusa API | ImportMedusa.ps1 |

**ManualImport Flow (Phase 3)**

The `Invoke-SAArrImport` function uses ManualImport API for a three-step process:

1. **SCAN** - Get files with metadata and rejections via `Invoke-SAArrManualImportScan`
2. **FILTER** - Use `Get-SAImportableFiles` and `Get-SARejectionSummary` to identify what can be imported
3. **IMPORT** - Execute import with `Invoke-SAArrManualImportExecute` for filtered files only

**Return Object Enhancement**

The import result includes rich metadata for email enrichment:

```powershell
@{
    Success         = $true/$false
    Message         = 'Imported' / error message
    Duration        = seconds
    ImportedFiles   = @(paths)
    SkippedFiles    = @(rejected paths)      # Files with permanent rejections
    ArrMetadata     = @{...}                 # Normalized metadata from scan
    SkippedCount    = count                  # Number of skipped files
    ErrorType       = 'quality'/'sample'/etc # For hint generation
    Skipped         = $true                  # Flag for all-skipped scenarios
    QualityRejected = $true                  # Flag for quality rejections
}
```

### Staging

| Function | Purpose | File |
|----------|---------|------|
| `Initialize-SAStagingFolder` | Create staging folder | Staging.ps1 |
| `Remove-SAStagingFolder` | Remove after processing | Staging.ps1 |

### Notifications

| Function | Purpose | File |
|----------|---------|------|
| `Send-SAEmail` | Send HTML email with optional inline image attachments | Notification.ps1 |
| `Test-SAEmailConfig` | Send test email | Notification.ps1 |
| `Get-SAEmailInlineImages` | Extract inline images from OmdbData for email | EmailHelpers.ps1 |

### State Management

| Function | Purpose | File |
|----------|---------|------|
| `Reset-SAJobState` | Reset all state between jobs | Utility.ps1 |

---

## Key Internal Helpers

These aren't exported but are heavily used internally:

### HTTP & Process

| Function | Purpose | File |
|----------|---------|------|
| `Invoke-SAWebRequest` | HTTP with retry/rate-limit | Http.ps1 |
| `New-SAHttpResult` | Standardized HTTP result | Http.ps1 |
| `Get-SAHttpRetryDelay` | Exponential backoff | Http.ps1 |
| `Test-SAHttpStatusRetryable` | Should retry? (429, 5xx) | Http.ps1 |
| `Invoke-SAProcess` | Run external process | Process.ps1 |
| `Invoke-SAProcessWithRetry` | Run external tool with automatic retry | ErrorHandling.ps1 |
| `Test-SAProcessResult` | Validate process result and log errors | ErrorHandling.ps1 |
| `Get-SAToolErrorInfo` | Translate tool exit codes to user-friendly errors | ErrorHandling.ps1 |
| `Write-SAToolError` | Write user-friendly error with guidance | ErrorHandling.ps1 |

### Formatting & Display

| Function | Purpose | File |
|----------|---------|------|
| `Format-SASize` | Bytes to "4.2 GB" | Formatting.ps1 |
| `Format-SADuration` | Seconds to "1m 23s" | Formatting.ps1 |
| `ConvertTo-SAHumanDuration` | TimeSpan to readable string | Formatting.ps1 |
| `Get-SAPluralForm` | "1 file" vs "3 files" | Formatting.ps1 |
| `Get-SATimestamp` | Format timestamp for display | Formatting.ps1 |
| `ConvertTo-SALanguageCode` | Normalize language codes | Language.ps1 |
| `Get-SALanguageInfo` | Full language info | Language.ps1 |

### Path & File Security

| Function | Purpose | File |
|----------|---------|------|
| `Get-SASafeName` | Sanitize for filesystem | PathSecurity.ps1 |
| `Assert-SAPathUnderRoot` | Security: path validation | PathSecurity.ps1 |
| `Test-SASamplePath` | Detect sample files | PathSecurity.ps1 |

### File I/O

| Function | Purpose | File |
|----------|---------|------|
| `New-SADirectory` | Create if not exists | FileIO.ps1 |
| `Write-SAFileUtf8NoBom` | Write UTF-8 without BOM | FileIO.ps1 |
| `Write-SAFileAtomicUtf8NoBom` | Atomic file write | FileIO.ps1 |
| `Write-SAFileLinesUtf8NoBom` | Write lines to file | FileIO.ps1 |

### Episode Formatting

| Function | Purpose | File |
|----------|---------|------|
| `Group-SAConsecutiveEpisodes` | Group episode numbers into ranges | EpisodeFormatting.ps1 |
| `Format-SAEpisodeRange` | Format single range "E01-E03" | EpisodeFormatting.ps1 |
| `Format-SAEpisodeList` | Format episode list compactly | EpisodeFormatting.ps1 |
| `Format-SAEpisodeOutcome` | Format episode outcome for display | EpisodeFormatting.ps1 |

### Media Parsing

| Function | Purpose | File |
|----------|---------|------|
| `Get-SAMediaInfo` | Parse media filename (extended fields) | MediaParsing.ps1 |
| `Get-SAGuessItInfo` | GuessIt API parsing (extended fields) | MediaParsing.ps1 |
| `Get-SAReleaseInfo` | Parse release (API + fallback) | MediaParsing.ps1 |
| `Get-SAFileEpisodeInfo` | Parse filename to structured episode info | MediaParsing.ps1 |

### Media Display

| Function | Purpose | File |
|----------|---------|------|
| `Get-SASourceDisplayName` | Source to compact name (UHD, WEB, BluRay, Remux) | MediaDisplay.ps1 |
| `Get-SAServiceDisplayName` | Service to abbreviation (NF, AMZN, HMAX) | MediaDisplay.ps1 |
| `Get-SAHdrDisplayName` | HDR tags to display name (Dolby Vision, HDR10+) | MediaDisplay.ps1 |
| `Get-SAQualityDisplayString` | Build quality string for email (bullet-separated) | MediaDisplay.ps1 |
| `Get-SAQualityLogString` | Build quality string for logs (space-separated) | MediaDisplay.ps1 |
| `Add-SAReleaseDisplayInfo` | Enrich ReleaseInfo with pre-computed display values | MediaDisplay.ps1 |

### Video Analysis

| Function | Purpose | File |
|----------|---------|------|
| `Get-SAMkvInfo` | MKV track analysis | MkvAnalysis.ps1 |
| `Get-SAVideoHash` | OpenSubtitles hash | MkvAnalysis.ps1 |

### Utilities

| Function | Purpose | File |
|----------|---------|------|
| `Get-SAHash` | SHA256 hash generation | Utility.ps1 |
| `Get-SAIsWindows` | Platform detection | Utility.ps1 |
| `ConvertTo-SAHashtable` | PSCustomObject to hashtable | Utility.ps1 |

### Import Utilities

| Function | Purpose | File |
|----------|---------|------|
| `Get-SAImporterBaseUrl` | Build importer URL with hostname resolution | ImportUtility.ps1 |
| `Convert-SAToRemotePath` | Translate local to remote paths | ImportUtility.ps1 |
| `Reset-SAHostnameCache` | Clear DNS resolution cache | ImportUtility.ps1 |
| `ConvertFrom-SAArrErrors` | Parse *arr error responses | ImportResultParser.ps1 |
| `ConvertFrom-SAMedusaOutput` | Parse Medusa output array | ImportResultParser.ps1 |
| `Get-SAMedusaFileDetails` | Extract per-file episode details | ImportResultParser.ps1 |
| `Get-SAMedusaSimplifiedReason` | Simplify Medusa reason text | ImportResultParser.ps1 |
| `Get-SAMedusaSameSizeSkipReason` | Get skip reason for "succeeded" without move | ImportResultParser.ps1 |
| `Get-SAImportHint` | Generate troubleshooting hints | ImportResultParser.ps1 |
| `Get-SAImportErrorMessage` | Build user-friendly error message | ImportResultParser.ps1 |
| `Get-SAImportSkipMessage` | Build skip message from error type | ImportResultParser.ps1 |
| `Get-SAImportErrorHints` | Generate user-friendly hints | ImportResultParser.ps1 |
| `Get-SAMedusaSeasonFromFiles` | Extract season from file detail arrays | ImportMedusa.ps1 |
| `Write-SAMedusaEpisodeOutcome` | Write episode-level outcome to console | ImportMedusa.ps1 |
| `Format-SAImportEpisodeNote` | Format episode details for email notes | JobProcessor.ps1 |

### Email Rendering

| Function | Purpose | File |
|----------|---------|------|
| `ConvertTo-SAHtmlSafe` | HTML-encode for safe rendering | Output/EmailHelpers.ps1 |
| `Get-SAEmailQualityDisplay` | Get pre-computed quality display for email | Output/EmailHelpers.ps1 |
| `Get-SAEmailFilesDisplay` | Format files info for email | Output/EmailHelpers.ps1 |
| `Get-SAEmailSubtitleDisplay` | Format subtitle info for email | Output/EmailHelpers.ps1 |
| `Get-SAEmailImportDisplay` | Format import info for email | Output/EmailHelpers.ps1 |
| `Get-SAEmailHtmlDocument` | Build complete HTML document | Output/EmailSections.ps1 |
| `Get-SAEmailStatusBadge` | Generate status badge HTML | Output/EmailSections.ps1 |
| `Get-SAEmailTitleSection` | Generate title/subtitle HTML (dispatches to centered or OMDb layout) | Output/EmailSections.ps1 |
| `Get-SAEmailCenteredTitleSection` | Generate centered title/subtitle (no OMDb) | Output/EmailSections.ps1 |
| `Get-SAEmailOmdbTitleSection` | Generate title with poster/ratings layout | Output/EmailSections.ps1 |
| `Get-SAEmailRatingsHtml` | Generate ratings HTML (⭐ IMDb • 🍅 RT • Ⓜ MC) | Output/EmailSections.ps1 |
| `Get-SAEmailSubtitle` | Category • Target string | Output/EmailSections.ps1 |
| `Get-SAEmailDetailsSection` | Generate details card HTML (includes Quality row) | Output/EmailSections.ps1 |
| `Format-SAEmailDetailRow` | Format detail row | Output/EmailSections.ps1 |
| `Get-SAEmailNotesSection` | Generate notes card HTML | Output/EmailSections.ps1 |
| `Get-SAEmailWhatHappenedSection` | Generate failure info HTML | Output/EmailSections.ps1 |
| `Get-SAEmailWhatToCheckSection` | Generate troubleshooting HTML | Output/EmailSections.ps1 |
| `Get-SAEmailTroubleshootingSuggestions` | Generate context-aware suggestions | Output/EmailSections.ps1 |
| `Get-SAEmailLogSection` | Generate log path HTML | Output/EmailSections.ps1 |
| `Get-SAEmailFooter` | Generate footer HTML | Output/EmailSections.ps1 |

### File Logging

| Function | Purpose | File |
|----------|---------|------|
| `Format-SAFileLogLine` | Format event for log file | Output/FileLogRenderer.ps1 |
| `Get-SAFileLogPath` | Generate log file path | Output/FileLogRenderer.ps1 |
| `Set-SAFileLogToolVersions` | Set tool versions for log header | Output/FileLogRenderer.ps1 |

---

## Pure Helper Functions (Unit Testable)

These have no I/O — input → output only:

**Http.ps1:** `New-SAHttpResult`, `Get-SAHttpRetryDelay`, `Test-SAHttpStatusRetryable`, `Test-SAHttpStatusAuthError`

**Omdb.ps1:** `ConvertTo-SAOmdbDisplayData` (API response normalization, rating extraction)

**Formatting.ps1:** `Format-SASize`, `Format-SADuration`, `ConvertTo-SAHumanDuration`, `Get-SAPluralForm`, `Get-SATimestamp`

**PathSecurity.ps1:** `Get-SASafeName`, `Assert-SAPathUnderRoot`, `Test-SASamplePath`

**FileIO.ps1:** `New-SADirectory`, `Write-SAFileUtf8NoBom`, `Write-SAFileAtomicUtf8NoBom`, `Write-SAFileLinesUtf8NoBom`

**EpisodeFormatting.ps1:** `Group-SAConsecutiveEpisodes`, `Format-SAEpisodeRange`, `Format-SAEpisodeList`, `Format-SAEpisodeOutcome`

**MediaParsing.ps1:** `Get-SAMediaInfo`, `Get-SAFileEpisodeInfo` (local release parsing with extended fields: ScreenSize, StreamingService, ReleaseGroup, Other, Source)

**MediaDisplay.ps1:** `Get-SASourceDisplayName`, `Get-SAServiceDisplayName`, `Get-SAHdrDisplayName`, `Get-SAQualityDisplayString`, `Get-SAQualityLogString`, `Add-SAReleaseDisplayInfo` (convert parsed metadata to scene-convention display names, HDR formatting, quality string building)

**Utility.ps1:** `Get-SAHash`, `Get-SAIsWindows`, `ConvertTo-SAHashtable`

**Language.ps1:** `ConvertTo-SALanguageCode`, `Test-SALanguageCode`, `Get-SALanguageInfo`

**SubtitleProcessing.ps1:** `Get-SAVideoExistingLanguages`, `Get-SAVideoMissingLanguages`, `Get-SASubtitleLanguageCounts`, `Format-SASubtitleSummary`, `Get-SAMissingLanguagesInfo`

**JobProcessor.ps1:** `Get-SAEmailMetadataSource`, `Get-SASubtitleLanguagesFromResult`, `Get-SAMissingLanguageNames`, `Get-SAImportTargetName`, `Get-SAImportResultText`, `Get-SAEmailResultLevel`, `Format-SAImportEpisodeNote`

**ErrorHandling.ps1:** `Get-SAToolErrorInfo` (error translation)

**Output/FileLogRenderer.ps1:** `Format-SAFileLogLine`, `Format-SAFileLogHeader`, `Format-SAFileLogMessage`, `Get-SAFileLogHeader`, `Get-SAFileLogFooter`

**Output/EmailHelpers.ps1:** `ConvertTo-SAHtmlSafe`, `Get-SAEmailQualityDisplay`, `Get-SAEmailFilesDisplay`, `Get-SAEmailSubtitleDisplay`, `Get-SAEmailImportDisplay`

**Output/EmailSubject.ps1:** `Get-SASubjectPresetTemplate`, `Format-SAEmailSubjectCleanup`, `Format-SAEmailSubject`, `Build-SASubjectPlaceholders`

**Output/EmailSections.ps1:** `Get-SAEmailSubtitle`, `Get-SAEmailRatingsHtml`, `Get-SAEmailTroubleshootingSuggestions`

**ImportResultParser.ps1:** `Get-SAMedusaFileDetails`, `Get-SAMedusaSimplifiedReason`, `Get-SAMedusaSameSizeSkipReason`, `Get-SAImportHint`, `Get-SAImportErrorMessage`, `Get-SAImportSkipMessage`

**ArrMetadata.ps1:** `ConvertTo-SAArrMetadata`, `Get-SAArrPosterData`, `Get-SAImportableFiles`, `Get-SARejectionSummary`, `Get-SASimplifiedRejectionReason` (*arr metadata extraction, local poster download, and rejection filtering)

**ImportArr.ps1:** `Get-SAErrorTypeFromRejection` (maps rejection reasons to error types for hint compatibility)

**ImportMedusa.ps1:** `Get-SAMedusaSeasonFromFiles`

**ConfigSync.ps1:** `Compare-SAConfigSchema`, `Get-SAConfigDescription`, `Merge-SAConfigFromSample`, `Remove-SAConfigComments` (config schema comparison and merging)

---

## Adding Features

### A) New Processing Step

1. **Pick the layer:**
   - Orchestration → `JobProcessor.ps1`
   - Implementation → specific module (Video/SubtitleProcessing/Import)

2. **Emit events consistently:**
   ```powershell
   Write-SAPhaseHeader -Title "My Step"
   Write-SAProgress -Label "Status" -Text "Doing work..."
   Write-SAOutcome -Level Success -Label "Step" -Text "Complete"
   ```

3. **Use standard helpers:**
   - External tools: `Invoke-SAProcess`
   - HTTP: `Invoke-SAWebRequest`

### B) New Integration (e.g., Lidarr)

1. Add config section to `config-sample.toml`
2. Follow patterns in `Import.ps1`:
   - `Test-TS<n>Connection`
   - `Invoke-TS<n>Import`
3. Use `Invoke-SAWebRequest` for API calls

### C) New Output Channel (Slack/Discord)

1. Create `Private/Output/<n>Renderer.ps1`
2. Implement `Initialize-TS<n>Renderer` and event handler
3. Hook into `Output/OutputEvent.ps1`
4. Add config toggle

---

## Design Notes

### Wrapper Functions (Intentionally Kept)

These wrappers provide semantic clarity and are intentionally retained:

| Wrapper | Calls | Why Kept |
|---------|-------|----------|
| `Invoke-SARadarrImport` | `Invoke-SAArrImport -AppType Radarr` | Clearer intent |
| `Invoke-SASonarrImport` | `Invoke-SAArrImport -AppType Sonarr` | Clearer intent |
| `Invoke-SARadarrManualImportScan` | `Invoke-SAArrManualImportScan -AppType Radarr` | Clearer intent |
| `Invoke-SASonarrManualImportScan` | `Invoke-SAArrManualImportScan -AppType Sonarr` | Clearer intent |
| `Invoke-SARadarrManualImportExecute` | `Invoke-SAArrManualImportExecute -AppType Radarr` | Clearer intent |
| `Invoke-SASonarrManualImportExecute` | `Invoke-SAArrManualImportExecute -AppType Sonarr` | Clearer intent |
| `Test-SARadarrConnection` | `Test-SAArrConnection -AppType Radarr` | Clearer intent |
| `Test-SASonarrConnection` | `Test-SAArrConnection -AppType Sonarr` | Clearer intent |
| `Get-SARadarrRecentErrors` | `Get-SAArrRecentErrors -AppType Radarr` | Clearer intent |
| `Get-SASonarrRecentErrors` | `Get-SAArrRecentErrors -AppType Sonarr` | Clearer intent |

The generic `Invoke-SAArrImport` handles all Radarr/Sonarr shared logic. Wrappers exist so calling code reads naturally: `Invoke-SARadarrImport` vs `Invoke-SAArrImport -AppType 'Radarr'`.

### Future Consolidation Candidates

`Get-SAMissingLanguageNames` in JobProcessor.ps1 should probably move to Language.ps1.

---

## Contributor Checklist

When adding/changing functions:

- [ ] Check "Before You Write New Code" table first
- [ ] Use approved PowerShell verbs (`Get-Verb`)
- [ ] Add to module load order if new file
- [ ] Update `Stagearr.Core.psd1` if exporting
- [ ] Update `config-sample.toml` if config changes
- [ ] Update this reference if significant