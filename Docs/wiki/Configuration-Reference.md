# Configuration Reference

Stagearr uses a TOML configuration file (`config.toml`). Copy `config-sample.toml` and customize — you only need to include settings you want to change from defaults.

> **Tip:** Use forward slashes (`C:/Path`) or double backslashes (`C:\\Path`) in TOML — single backslashes are treated as escape characters.

---

## Paths

```toml
[paths]
stagingRoot = "C:/Staging"
logArchive = "C:/Logs/Stagearr"
queueRoot = "C:/Stagearr-ps/Queue"
downloadRoot = "C:/Downloads"
```

| Option | Description | Default |
|--------|-------------|---------|
| `stagingRoot` | Working directory for file processing | (required) |
| `logArchive` | Directory for saved log files | (required) |
| `queueRoot` | Directory for job queue state files | (required) |
| `downloadRoot` | Root of torrent download folder. Required for `-Rerun` on multi-server setups where each server mounts the download folder at a different path. | `""` |

---

## Labels

Map your torrent client labels to content types:

```toml
[labels]
tv = "tv"
movie = "movie"
skip = "skip"
tvLabels = ["tv", "sonarr", "series"]
movieLabels = ["movie", "radarr", "film"]
```

| Option | Description | Default |
|--------|-------------|---------|
| `tv` | Primary TV label | `"tv"` |
| `movie` | Primary movie label | `"movie"` |
| `skip` | Label to skip processing entirely | `"skip"` |
| `tvLabels` | All labels treated as TV content | `["tv", "sonarr", "series"]` |
| `movieLabels` | All labels treated as movie content | `["movie", "radarr", "film"]` |

Labels not in either list trigger **passthrough mode** — files are extracted/copied but no video processing or media server import occurs.

---

## Processing

```toml
[processing]
tvImporter = "Medusa"       # Medusa | Sonarr
cleanupStaging = true       # Remove staging folder after processing
staleLockMinutes = 15       # Release lock if held longer than this (crash recovery)
```

---

## External Tools

Paths to external tools. Only needed for features you enable.

```toml
[tools]
winrar = "C:/Program Files/WinRAR/RAR.exe"
mkvmerge = "C:/Program Files/MKVToolNix/mkvmerge.exe"
mkvextract = "C:/Program Files/MKVToolNix/mkvextract.exe"
subtitleEdit = "C:/Program Files/Subtitle Edit/SubtitleEdit.exe"
```

---

## Video Processing

```toml
[video.mp4Remux]
enabled = true    # Remux MP4/M4V to MKV container. Requires mkvmerge.
```

---

## Subtitles

```toml
[subtitles]
wantedLanguages = ["eng", "nld"]
namePatternsToRemove = ["Forced", "Signs", "Songs"]
```

| Option | Description | Default |
|--------|-------------|---------|
| `wantedLanguages` | ISO 639 language codes to keep | `["eng", "nld"]` |
| `namePatternsToRemove` | Track name patterns to strip (only if clean alternative exists) | `["Forced", "Signs", "Songs"]` |

### Extraction

```toml
[subtitles.extraction]
enabled = true
duplicateLanguageMode = "all"    # all | largest
```

| Option | Description | Default |
|--------|-------------|---------|
| `enabled` | Extract text subtitle tracks from MKV to SRT files. Requires mkvextract. | `true` |
| `duplicateLanguageMode` | `all` keeps all with numeric suffixes; `largest` keeps only the biggest track per language | `"all"` |

### Stripping

```toml
[subtitles.stripping]
enabled = true    # Remove unwanted subtitle tracks from MKV. Requires mkvmerge.
```

### Cleanup

```toml
[subtitles.cleanup]
enabled = true    # Clean subtitles with SubtitleEdit (removes HI tags, fixes errors)
```

### OpenSubtitles

```toml
[subtitles.openSubtitles]
enabled = true
user = "your_username"
password = "your_password"
apiKey = "your_api_key"
uploadCleaned = false
uploadDiagnosticMode = false
uploadExclude = []

[subtitles.openSubtitles.filters]
hearingImpaired = "exclude"     # include | exclude | only
foreignPartsOnly = "exclude"
machineTranslated = "exclude"
aiTranslated = "include"
```

| Option | Description | Default |
|--------|-------------|---------|
| `enabled` | Enable OpenSubtitles subtitle downloading | `false` |
| `user` | OpenSubtitles.com username | (required) |
| `password` | OpenSubtitles.com password | (required) |
| `apiKey` | OpenSubtitles.com API key | (required) |
| `uploadCleaned` | Upload cleaned subtitles (extracted only, not downloaded) back to OpenSubtitles | `false` |
| `uploadDiagnosticMode` | Log what would be uploaded without actually uploading | `false` |
| `uploadExclude` | Shows/movies to never upload for. Accepts IMDB IDs (`"tt2140481"`) or titles (case-insensitive) | `[]` |

See [Subtitle Processing](Subtitle-Processing) for details on filters and upload behavior.

---

## Importer Prerequisites

Stagearr uses the ManualImport API to send **processed** files (with cleaned subtitles, stripped tracks, etc.) to Sonarr/Radarr. If Completed Download Handling is active, the *arr app will auto-import the **raw** torrent files before Stagearr has a chance to process them. You must prevent this.

### Option A — Bogus Download Folder (Recommended)

1. In Sonarr/Radarr, go to **Settings > Download Clients** and select your qBittorrent client
2. Set the **download folder** (or root folder path) to an empty folder that will never contain downloads (e.g., `C:\Empty` or `/data/empty`)
3. If you use **Remote Path Mapping** in the *arr app, map the download client's path to this empty folder
4. The *arr app will look for completed downloads there, find nothing, and never auto-import

This is the preferred approach because it preserves the *arr app's ability to track download progress and display queue status, while still preventing auto-import. Stagearr bypasses this entirely by using the ManualImport API with explicit file paths.

### Option B — Disable Completed Download Handling

1. In Sonarr/Radarr, go to **Settings > Download Clients**
2. Disable **Completed Download Handling**

This prevents the *arr app from monitoring the download client for completed downloads entirely.

---

## Importers

### Radarr (Movies)

```toml
[importers.radarr]
enabled = true
host = "localhost"
port = 7878
apiKey = "your_radarr_api_key"
ssl = false
urlRoot = ""
timeoutMinutes = 10
remotePath = ""
importMode = "move"
```

### Sonarr (TV Shows)

```toml
[importers.sonarr]
enabled = true
host = "localhost"
port = 8989
apiKey = "your_sonarr_api_key"
ssl = false
urlRoot = ""
timeoutMinutes = 10
remotePath = ""
importMode = "move"
```

### Medusa (TV Shows)

```toml
[importers.medusa]
enabled = false
host = "localhost"
port = 8081
apiKey = "your_medusa_api_key"
ssl = false
urlRoot = ""
timeoutMinutes = 15
remotePath = ""
```

### Importer Options

| Option | Description | Default |
|--------|-------------|---------|
| `enabled` | Enable this importer | varies |
| `host` | Server hostname or IP | `"localhost"` |
| `port` | Server port | varies |
| `apiKey` | API key for authentication | (required) |
| `ssl` | Use HTTPS instead of HTTP | `false` |
| `urlRoot` | URL base path for reverse proxy (e.g., `/radarr`) | `""` |
| `timeoutMinutes` | Max time to wait for import completion | `10`/`15` |
| `remotePath` | Path translation when importer sees different paths than script | `""` |
| `importMode` | How to handle source files: `move` or `copy` (Radarr/Sonarr only) | `"move"` |

### Remote Path Mapping

When Stagearr tells Radarr/Sonarr/Medusa to import files, it sends a **file path**. If the importer sees the filesystem differently than the machine running Stagearr, that path won't resolve. This is common with:

- **Docker containers** — The *arr app runs inside a container where paths are mapped differently (e.g., `/data/staging` inside the container vs `C:\Staging` on the host)
- **NAS / network storage** — Stagearr writes to a local path that the importer accesses via a different mount or UNC path
- **Different machines** — Stagearr runs on one server, the *arr app runs on another

`remotePath` translates the local staging path to the path the importer expects. The relative folder structure (label subfolder + release folder) is preserved automatically.

**Example: Docker**

Stagearr stages files to `C:\Staging\Movie\Movie.Name.2025`. Radarr runs in Docker with `C:\Staging` mapped to `/data/staging`:

```toml
[importers.radarr]
remotePath = "/data/staging"
```

Stagearr sends `/data/staging/Movie/Movie.Name.2025` to Radarr instead of `C:\Staging\Movie\Movie.Name.2025`.

**Example: NAS / UNC path**

Stagearr stages to `D:\Processing` on the local machine. Sonarr accesses the same storage via `\\nas\processing`:

```toml
[importers.sonarr]
remotePath = "\\\\nas\\processing"
```

> **Note:** In TOML, backslashes must be doubled (`\\\\`) or use forward slashes instead.

**How it works:** When `remotePath` is set, Stagearr takes the relative path under `paths.stagingRoot` (e.g., `TV\Show.Name`) and appends it to `remotePath`. The importer receives the translated path and can access the files through its own mount.

**When to leave it empty:** If Stagearr and the importer run on the same machine and see the same filesystem paths, leave `remotePath` as `""` — no translation is needed.

---

## Email Notifications

```toml
[notifications.email]
enabled = false
to = "you@example.com"
from = "stagearr@example.com"
fromName = "Stagearr"
subjectStyle = "detailed"
subjectTemplate = "{result}{label}: {name} [{resolution} {source}-{group}]"

[notifications.email.smtp]
server = "smtp.gmail.com"
port = 587
user = "your_smtp_username"
password = "your_smtp_password_or_app_password"
```

> **Gmail Users:** Use an [App Password](https://support.google.com/accounts/answer/185833) instead of your regular password.

See [Email Notifications](Email-Notifications) for subject styles, templates, and metadata enrichment options.

### Email Metadata

```toml
[notifications.email.metadata]
source = "auto"    # auto | omdb | none
```

| Option | Description | Default |
|--------|-------------|---------|
| `metadata.source` | `auto` merges *arr ratings with OMDb poster; `omdb` uses OMDb only; `none` disables | `"auto"` |

---

## OMDb (Optional)

For metadata enrichment when using Medusa, or to force OMDb for all imports.

```toml
[omdb]
enabled = false
apiKey = ""
timeoutSeconds = 5

[omdb.poster]
enabled = true

[omdb.display]
plot = false
plotMaxLength = 150
```

Get a free API key at [omdbapi.com](https://www.omdbapi.com/apikey.aspx) (1,000 requests/day).

| Option | Description | Default |
|--------|-------------|---------|
| `enabled` | Enable OMDb API calls | `false` |
| `apiKey` | Your OMDb API key | (required when enabled) |
| `timeoutSeconds` | API request timeout | `5` |
| `poster.enabled` | Embed movie poster in email | `true` |
| `display.plot` | Show plot summary | `false` |
| `display.plotMaxLength` | Max characters for plot | `150` |

---

## Logging

```toml
[logging]
dateFormat = "yyyy-MM-dd HH:mm:ss"
consoleColors = true
```

| Option | Description | Default |
|--------|-------------|---------|
| `dateFormat` | Timestamp format for log filenames | `"yyyy.MM.dd_HH.mm.ss"` |
| `consoleColors` | Enable colored console output | `true` |

---

## Feature Flags Summary

| Feature | Config Path | Default | Required Tool |
|---------|-------------|---------|---------------|
| MP4 to MKV Remux | `video.mp4Remux.enabled` | `true` | mkvmerge |
| Subtitle Extraction | `subtitles.extraction.enabled` | `true` | mkvextract |
| Subtitle Stripping | `subtitles.stripping.enabled` | `true` | mkvmerge |
| SubtitleEdit Cleanup | `subtitles.cleanup.enabled` | `true` | SubtitleEdit |
| OpenSubtitles | `subtitles.openSubtitles.enabled` | `false` | (API only) |
| Subtitle Upload | `subtitles.openSubtitles.uploadCleaned` | `false` | (API only) |
| OMDb Enrichment | `omdb.enabled` | `false` | (API only) |
