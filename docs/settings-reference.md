# Settings Reference

All settings live in `config.toml` in the repository root. Copy `config-sample.toml` to get started. See [Configuration Overview](configuration.md) for how the file is loaded and merged with defaults.

Every key in this reference is listed in the order it appears in `config-sample.toml`. Defaults shown are the built-in code defaults from `Config.ps1`; the sample file may show different values as opinionated starting points.

---

## [paths]

File system paths for working directories. All three main paths are **required** (no default; startup fails without them).

Use forward slashes or double backslashes. See [Configuration Overview](configuration.md#path-format-in-toml).

| Key | Description | Default |
|-----|-------------|---------|
| `stagingRoot` | Working directory where files are copied or extracted before processing. | (required) |
| `logArchive` | Directory where completed job log files are saved. | (required) |
| `queueRoot` | Directory for job queue state files (pending / running / completed). | (required) |
| `downloadRoot` | Root of the torrent download folder on this machine. Only needed for `-Rerun` on multi-server setups where each server mounts the download folder at a different path. | `""` |

---

## [labels]

Maps torrent client labels to content types. These should match the labels you assign in qBittorrent.

| Key | Description | Default |
|-----|-------------|---------|
| `tv` | Primary label for TV content. | `"TV"` |
| `movie` | Primary label for movie content. | `"Movie"` |
| `skip` | Label to skip all processing. The torrent is acknowledged but nothing is done. | `"NoProcess"` |
| `tvLabels` | Additional labels treated as TV (merged with `tv`). | `[]` |
| `movieLabels` | Additional labels treated as movies (merged with `movie`). | `[]` |

The `tv` and `movie` values are always matched regardless of `tvLabels` / `movieLabels`. The arrays let you add aliases without replacing the primary label.

Any label not matched by any of the above triggers passthrough mode. See [Labels & Content Routing](labels.md) for details.

---

## [processing]

Controls how jobs are run.

| Key | Description | Default |
|-----|-------------|---------|
| `tvImporter` | Which importer to use for TV content. Accepted values: `Sonarr`, `Medusa`. | `"Sonarr"` |
| `cleanupStaging` | Remove the staging folder after a job completes. Set to `false` for debugging. | `true` |
| `heartbeatSeconds` | How often the active worker writes a heartbeat to the global lock file (liveness proof). | `30` |
| `staleHeartbeatSeconds` | How many seconds with no heartbeat before another worker may take the lock (crash recovery). Requires NTP-synced clocks on all machines sharing the queue folder. | `120` |

See [Job Queue & Locking](queue-locking.md) for how the heartbeat lock works.

---

## [tools]

Paths to external executables. Only configure the tools required by the features you enable.

| Key | Description | Required when |
|-----|-------------|---------------|
| `winrar` | Path to `RAR.exe` (WinRAR). | Always (RAR extraction is core functionality). |
| `mkvmerge` | Path to `mkvmerge.exe` (MKVToolNix). | `video.mp4Remux.enabled = true` or `subtitles.stripping.enabled = true`. |
| `mkvextract` | Path to `mkvextract.exe` (MKVToolNix). | `subtitles.extraction.enabled = true`. |
| `subtitleEdit` | Path to the Subtitle Edit install folder (recommended) or a specific binary (`SubtitleEdit.exe` or `seconv`). When given a folder, seconv is used automatically if present; otherwise SubtitleEdit.exe is used. | `subtitles.cleanup.enabled = true`. |

Example (install-folder form, recommended):

```toml
[tools]
winrar       = "C:/Program Files/WinRAR/RAR.exe"
mkvmerge     = "C:/Program Files/MKVToolNix/mkvmerge.exe"
mkvextract   = "C:/Program Files/MKVToolNix/mkvextract.exe"
subtitleEdit = "C:/Program Files/Subtitle Edit"
```

---

## [video.mp4Remux]

Controls automatic remuxing of MP4 and M4V files into the MKV container.

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Remux MP4/M4V files to MKV. Requires `tools.mkvmerge`. Disable if all your content is already MKV. | `true` |

See [Video Processing](video-processing.md) for what remuxing does and does not change.

---

## [subtitles]

Top-level subtitle preferences applied across all subtitle features.

| Key | Description | Default |
|-----|-------------|---------|
| `wantedLanguages` | ISO 639-2 language codes to keep and download. Tracks in other languages are candidates for stripping. | `["eng"]` |
| `namePatternsToRemove` | Subtitle track names matching these patterns are removed during stripping, but only when a clean alternative in the same language already exists. | `["Forced"]` |

### [subtitles.extraction]

Extracts text (SRT-compatible) subtitle tracks from MKV files to external `.srt` files.

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Extract subtitle tracks to SRT files. Requires `tools.mkvextract`. | `true` |
| `duplicateLanguageMode` | How to handle multiple tracks of the same language. `all` keeps all tracks with numeric suffixes (`.en.srt`, `.en.1.srt`); `largest` keeps only the largest track per language. | `"all"` |

### [subtitles.stripping]

Removes unwanted subtitle tracks from the MKV file itself.

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Remove tracks not in `wantedLanguages` (and name-matched tracks per `namePatternsToRemove`). Requires `tools.mkvmerge`. | `true` |

### [subtitles.cleanup]

Cleans extracted and downloaded SRT files using the subtitle cleanup engine selected by `tools.subtitleEdit`. Both the seconv and SubtitleEdit.exe engines support all four operation toggles. The seconv-only keys apply only when seconv is the active engine.

| Key | Type | Description | Default |
|-----|------|-------------|---------|
| `enabled` | bool | Clean subtitles with the subtitle cleanup engine. Requires `tools.subtitleEdit`. | `true` |
| `removeHearingImpaired` | bool | Remove hearing-impaired annotations: `[brackets]` and `(parentheses)` tags such as `[door closes]`. | `true` |
| `mergeSameTexts` | bool | Merge consecutive identical subtitle lines into a single cue. | `true` |
| `fixCommonErrors` | bool | Fix OCR errors, encoding artifacts, and common formatting mistakes. | `true` |
| `splitLongLines` | bool | Split lines that exceed the display width across two lines. | `false` |
| `fixCommonErrorsRules` | string | **seconv only.** Comma-separated list of FixCommonErrors rules to apply. Prefix a rule name with `-` to exclude it. Default excludes `FixShortGaps` (shifts timecodes) and `FixShortLinesPixelWidth` (re-flows line breaks). | `"all,-FixShortGaps,-FixShortLinesPixelWidth"` |
| `seconvSettings` | string | **seconv only.** Path to a custom seconv settings JSON file that controls how operations behave (font, margins, per-rule parameters). Leave empty to use the bundled SE4 default profile. | `""` |

See [Subtitle Processing](subtitles.md#subtitle-cleanup) for a full description of the two engines, the two-layer model (which operations run vs. how they behave), and known limitations.

### [subtitles.openSubtitles]

Downloads missing subtitles from [OpenSubtitles.com](https://www.opensubtitles.com/) using the REST API v1. Disabled by default; requires an account and API key.

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable OpenSubtitles downloading. | `false` |
| `user` | OpenSubtitles.com username. Required when enabled. | `""` |
| `password` | OpenSubtitles.com password. Required when enabled. | `""` |
| `apiKey` | OpenSubtitles.com API key. Required when enabled. Get one at [opensubtitles.com](https://www.opensubtitles.com/en/consumers). | `""` |
| `uploadCleaned` | Upload cleaned subtitles (extracted or externally sourced, not downloaded) back to OpenSubtitles after cleanup. | `false` |
| `uploadDiagnosticMode` | Log what would be uploaded without actually uploading. Use this to verify upload guards before going live. | `false` |
| `uploadExclude` | Shows or movies to never upload subtitles for. Accepts IMDB IDs (e.g. `"tt2140481"`) or titles (case-insensitive match against the title from Radarr/Sonarr/OMDb). | `[]` |

#### [subtitles.openSubtitles.filters]

Filter which subtitles OpenSubtitles returns. Each filter accepts: `include`, `exclude`, or `only`.

| Key | Description | Default |
|-----|-------------|---------|
| `hearingImpaired` | Subtitles with hearing-impaired annotations. | `"exclude"` |
| `foreignPartsOnly` | Subtitles that only cover non-native-language parts. | `"exclude"` |
| `machineTranslated` | Machine-translated subtitles. | `"exclude"` |
| `aiTranslated` | AI-translated subtitles. | `"include"` |

See [Subtitle Processing](subtitles.md) for details on how downloading and uploading work.

---

## [importers.radarr]

Connects Stagearr to a Radarr instance for movie imports.

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable Radarr imports. | `false` |
| `host` | Radarr hostname or IP address. | `"localhost"` |
| `port` | Radarr port. | `7878` |
| `apiKey` | Radarr API key. Required when enabled. | `""` |
| `ssl` | Use HTTPS instead of HTTP. | `false` |
| `urlRoot` | URL base path when Radarr is behind a reverse proxy (e.g. `"/radarr"`). | `""` |
| `timeoutMinutes` | Maximum time to wait for Radarr to complete the import. | `15` |
| `remotePath` | Path prefix Radarr uses to reach the staging folder when it mounts the filesystem differently than Stagearr. See below. | `""` |
| `importMode` | How Radarr handles the source file after import. `move` removes the staged file; `copy` leaves it. | `"move"` |

---

## [importers.sonarr]

Connects Stagearr to a Sonarr instance for TV imports. Set `processing.tvImporter = "Sonarr"` to use this importer for TV content.

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable Sonarr imports. | `false` |
| `host` | Sonarr hostname or IP address. | `"localhost"` |
| `port` | Sonarr port. | `8989` |
| `apiKey` | Sonarr API key. Required when enabled. | `""` |
| `ssl` | Use HTTPS instead of HTTP. | `false` |
| `urlRoot` | URL base path when Sonarr is behind a reverse proxy (e.g. `"/sonarr"`). | `""` |
| `timeoutMinutes` | Maximum time to wait for Sonarr to complete the import. | `15` |
| `remotePath` | Path prefix Sonarr uses to reach the staging folder. See below. | `""` |
| `importMode` | How Sonarr handles the source file after import. `move` or `copy`. | `"move"` |

---

## [importers.medusa]

Connects Stagearr to a Medusa instance for TV imports. Set `processing.tvImporter = "Medusa"` to use this importer for TV content.

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable Medusa imports. | `false` |
| `host` | Medusa hostname or IP address. | `"localhost"` |
| `port` | Medusa port. | `8081` |
| `apiKey` | Medusa API key. Required when enabled. | `""` |
| `ssl` | Use HTTPS instead of HTTP. | `false` |
| `urlRoot` | URL base path when Medusa is behind a reverse proxy. | `""` |
| `timeoutMinutes` | Maximum time to wait for Medusa to complete the import. | `15` |
| `remotePath` | Path prefix Medusa uses to reach the staging folder. See below. | `""` |

---

### Remote path mapping

When Stagearr tells an importer to process a file, it sends the staging path. If the importer runs in a different environment (Docker container, different machine, NAS mount), it may see the same files at a different path. Set `remotePath` to the path the importer expects instead of the local `paths.stagingRoot` root.

Stagearr preserves the relative folder structure (label subfolder and release folder) under whichever root is in use.

**Example: Docker**

Stagearr stages to `C:\Staging`. Radarr runs in Docker with `C:\Staging` mapped to `/data/staging`:

```toml
[importers.radarr]
remotePath = "/data/staging"
```

Radarr receives `/data/staging/Movie/Movie.Name.2025` instead of `C:\Staging\Movie\Movie.Name.2025`.

**Example: NAS / UNC path**

Stagearr stages to `D:\Processing`. Sonarr accesses the same storage as `\\nas\processing`:

```toml
[importers.sonarr]
remotePath = "\\\\nas\\processing"
```

In TOML, backslashes must be doubled. Forward slashes also work if the importer accepts them.

Leave `remotePath` empty when Stagearr and the importer share the same filesystem paths.

See [Importing to Radarr / Sonarr / Medusa](importing.md) for prerequisites and how the ManualImport API is used.

---

## [notifications.email]

Sends an HTML email report after each job. Disabled by default.

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable email notifications. | `false` |
| `to` | Recipient address. Required when enabled. | `""` |
| `from` | Sender address. Required when enabled. | `""` |
| `fromName` | Display name shown in the From field. | `"Stagearr"` |
| `subjectStyle` | Preset subject format. See [Email Notifications](email.md) for all styles. | `"detailed"` |
| `subjectTemplate` | Custom subject line template. Used when `subjectStyle = "custom"`. | `""` |

Available `subjectStyle` values: `detailed`, `quality`, `source`, `group`, `hash`, `none`, `custom`.

### [notifications.email.smtp]

SMTP connection settings.

| Key | Description | Default |
|-----|-------------|---------|
| `server` | SMTP server hostname. Required when email is enabled. | `""` |
| `port` | SMTP port. | `465` |
| `user` | SMTP username. | `""` |
| `password` | SMTP password or app password. | `""` |

Gmail users: use an [App Password](https://support.google.com/accounts/answer/185833) (port 587 with STARTTLS, or port 465 with SSL).

### [notifications.email.metadata]

Controls which metadata source enriches the email with ratings, genre, and poster.

| Key | Description | Default |
|-----|-------------|---------|
| `source` | `auto` merges Radarr/Sonarr ratings with the OMDb poster when available; `omdb` uses OMDb only; `none` disables metadata enrichment entirely. | `"auto"` |

See [Email Notifications](email.md) for how metadata is fetched and displayed.

---

## [omdb]

Optional OMDb API integration for fetching movie metadata (poster, plot, ratings) for email enrichment. Useful when using Medusa (which does not provide ratings) or to force OMDb for all imports.

Get a free API key (1,000 requests/day) at [omdbapi.com](https://www.omdbapi.com/apikey.aspx).

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable OMDb API calls. | `false` |
| `apiKey` | OMDb API key. Required when enabled. | `""` |
| `timeoutSeconds` | HTTP request timeout for OMDb API calls. | `5` |

### [omdb.poster]

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Embed the OMDb movie poster image in the email. | `true` |

### [omdb.display]

| Key | Description | Default |
|-----|-------------|---------|
| `plot` | Include the plot synopsis in the email. | `false` |
| `plotMaxLength` | Maximum character length of the plot text before truncation. | `150` |

---

## [mdblist]

Optional MDBList API integration for marking imported movies and TV shows as collected (In Library) on MDBList. Disabled by default; requires a free account and API key. Movies are marked at the title level; a fully-downloaded show is marked show-level (so it leaves "not collected" lists), while a partially-downloaded show is marked per-episode.

Get your API key at [mdblist.com/preferences/](https://mdblist.com/preferences/) under the API section. No paid subscription is required.

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable MDBList collection sync after a successful import. | `false` |
| `apiKey` | MDBList API key. Required when enabled. | `""` |
| `timeoutSeconds` | HTTP request timeout for MDBList API calls. | `10` |

See [MDBList Collection Sync](mdblist.md) for what it does and how it behaves.

---

## [updates]

Controls automatic update checking from GitHub Releases.

| Key | Description | Default |
|-----|-------------|---------|
| `mode` | `auto` downloads and applies updates automatically; `notify` shows an update notice in email and console without applying; `off` disables all update checking. | `"auto"` |
| `checkIntervalHours` | Minimum hours between update checks. Set to `0` to check on every run. | `24` |

See [Auto-Update](updates.md) for how updates are applied and how to roll back.

---

## [logging]

| Key | Description | Default |
|-----|-------------|---------|
| `dateFormat` | .NET date format string used in log file names. | `"yyyy.MM.dd_HH.mm.ss"` |
| `consoleColors` | Enable colored console output. Set to `false` to disable ANSI color codes (useful when piping output). | `true` |

---

## Feature Flags Summary

| Feature | Config key | Default | Required tool |
|---------|-----------|---------|---------------|
| MP4 to MKV remux | `video.mp4Remux.enabled` | `true` | `tools.mkvmerge` |
| Subtitle extraction | `subtitles.extraction.enabled` | `true` | `tools.mkvextract` |
| Subtitle track stripping | `subtitles.stripping.enabled` | `true` | `tools.mkvmerge` |
| Subtitle cleanup | `subtitles.cleanup.enabled` | `true` | `tools.subtitleEdit` |
| OpenSubtitles download | `subtitles.openSubtitles.enabled` | `false` | (API credentials) |
| Subtitle upload | `subtitles.openSubtitles.uploadCleaned` | `false` | (API credentials) |
| OMDb enrichment | `omdb.enabled` | `false` | (API key) |
| Auto-update | `updates.mode` | `"auto"` | git |
