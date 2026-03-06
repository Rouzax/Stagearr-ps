# Email Notifications

Stagearr sends mobile-optimized, dark-themed HTML emails with status-appropriate styling and rich metadata.

---

## Email Types

| Type | Badge | Description |
|------|-------|-------------|
| **Success** | Green — "SUCCESS" | Files processed, subtitles, import status, duration |
| **Warning** | Amber — "WARNING" | Partial success with notes (e.g., missing subtitles) |
| **Failed** | Red — "FAILED" | "What Happened" + "What to Check" sections |
| **Passthrough** | Green — "SUCCESS" | Simplified view for non-media content |

### Screenshots

<p align="center">
  <img src="../images/email-success.png" alt="Success Email with metadata" width="270">
  <img src="../images/email-warning.png" alt="Warning Email with metadata" width="270">
</p>
<p align="center">
  <img src="../images/email-failed.png" alt="Failed Email" width="270">
  <img src="../images/email-passthrough.png" alt="Passthrough Email" width="270">
</p>

#### Without Metadata Enrichment

<p align="center">
  <img src="../images/email-success-no-metadata.png" alt="Success Email without metadata" width="270">
</p>

---

## Email Layout

```
+-----------------------------------------------------+
|                                                     |
|              +---------------------+               |
|              |    SUCCESS          |   <- Green     |
|              +---------------------+               |
|                                                     |
|   Wake Up Dead Man: A Knives Out Mystery (2025)    |
|   Movie - Radarr                                   |
|                                                     |
|   +---------------------------------------------+   |
|   | DETAILS                                     |   |
|   +---------------------------------------------+   |
|   | Source      Wake.Up.Dead.Man.2025.2160p... |   |
|   | Quality     2160p WEB - Dolby Vision       |   |
|   | Files       1 video (12.8 GB)              |   |
|   | Subtitles   English, Dutch                 |   |
|   | Import      Imported to library            |   |
|   | Duration    2m 34s                         |   |
|   +---------------------------------------------+   |
|                                                     |
|   Log: C:\Logs\2026-01-01_movie_wake-up-dead.log   |
|                                                     |
+-----------------------------------------------------+
```

**Quality Row:** Automatically displays parsed resolution, source, and HDR format (e.g., "2160p WEB - Dolby Vision", "1080p BluRay - HDR10+"). Omitted for passthrough/non-media content.

---

## Subject Line Styles

Control email subjects with `notifications.email.subjectStyle`:

| Style | Example | Description |
|-------|---------|-------------|
| `detailed` | `Movie: Inception (2010) [2160p UHD-CiNEPHiLES]` | Resolution + source + group (default) |
| `quality` | `Movie: Inception (2010) [2160p]` | Resolution only |
| `source` | `Movie: Inception (2010) [BluRay-CiNEPHiLES]` | Source + group |
| `group` | `Movie: Inception (2010) [-CiNEPHiLES]` | Release group only |
| `hash` | `Movie: Inception (2010) [a1b2]` | Torrent hash (always unique) |
| `none` | `Movie: Inception (2010)` | Clean, no metadata |
| `custom` | (your template) | Use `subjectTemplate` |

### Preset Templates

| Preset | Template |
|--------|----------|
| `detailed` | `{result}{label}: {name} [{resolution} {source}-{group}]` |
| `quality` | `{result}{label}: {name} [{resolution}]` |
| `source` | `{result}{label}: {name} [{source}-{group}]` |
| `group` | `{result}{label}: {name} [-{group}]` |
| `hash` | `{result}{label}: {name} [{hash4}]` |
| `none` | `{result}{label}: {name}` |

### Custom Templates

Set `subjectStyle` to `"custom"` and define your own format:

```toml
[notifications.email]
subjectStyle = "custom"
subjectTemplate = "{result}{name} [{service} {resolution}]"
```

### Available Placeholders

| Placeholder | Description | Example Values |
|-------------|-------------|----------------|
| `{result}` | Status prefix (auto) | `Failed: `, `Skipped: `, or empty |
| `{label}` | qBittorrent label | `Movie`, `TV`, `software` |
| `{name}` | Friendly media name | `Inception (2010)` |
| `{resolution}` | Video resolution | `2160p`, `1080p`, `720p` |
| `{source}` | Media source | `UHD`, `Remux`, `BluRay`, `WEB` |
| `{group}` | Release group | `NTb`, `SPARKS`, `CiNEPHiLES` |
| `{service}` | Streaming service | `NF`, `AMZN`, `DSNP`, `HMAX` |
| `{hash4}` | First 4 chars of torrent hash | `a1b2` |

**Smart cleanup:** Empty placeholders and orphaned brackets are automatically removed (e.g., `[2160p -]` becomes `[2160p]`).

---

## Metadata Enrichment

Enrich emails with posters, ratings, and metadata from multiple sources:

```
+----------+  Wake Up Dead Man: A Knives Out Mystery (2025)
|          |  IMDb 7.4  -  RT 85%  -  MC 80
|  POSTER  |  Comedy, Crime, Drama  -  144 min
|   80px   |  Movie - Radarr
|          |  -> View on IMDb
+----------+
```

### Metadata Sources

| Source | Provider | When Used | API Key Required |
|--------|----------|-----------|------------------|
| **Radarr/Sonarr** | TMDb (via *arr API) | Movie/TV imports to Radarr or Sonarr | No |
| **OMDb** | OMDb API | Medusa imports, or when forced via config | Yes (free) |

### Source Priority

```
Radarr/Sonarr Import          Medusa Import
        |                            |
        v                            v
  +-----------+              +-----------+
  | TMDb Data |              | OMDb API  |
  | (auto)    |              | (if on)   |
  +-----------+              +-----------+
        |                            |
        +----------+-----------------+
                   v
            +-----------+
            | Email w/  |
            | Poster +  |
            | Ratings   |
            +-----------+
```

> **Radarr/Sonarr users:** Metadata enrichment works automatically — no API key needed! The ManualImport API returns TMDb metadata including poster URL, ratings, genre, and runtime.

> **Medusa users:** Enable OMDb integration to get metadata enrichment (see below).

### Configuration

```toml
[notifications.email.metadata]
source = "auto"    # auto | omdb | none

[notifications.email.metadata.poster]
size = "w185"      # w92 | w185 | w500 | original
```

| Value | Behavior |
|-------|----------|
| `auto` | Use Radarr/Sonarr data when available, fall back to OMDb for Medusa |
| `omdb` | Always use OMDb API (ignores *arr metadata) |
| `none` | Disable metadata enrichment entirely |

### Poster Sizes

| Size | Dimensions | File Size | Use Case |
|------|------------|-----------|----------|
| `w92` | 92px wide | ~10-20KB | Minimal |
| `w185` | 185px wide | ~30-50KB | Recommended |
| `w500` | 500px wide | ~100-150KB | High-res displays |
| `original` | Full resolution | Varies | Maximum quality |

---

## OMDb Setup (for Medusa Users)

If you use Medusa for TV imports, enable OMDb for metadata enrichment:

1. Get a free API key at [omdbapi.com](https://www.omdbapi.com/apikey.aspx) (1,000 requests/day)
2. Enable in config:

```toml
[omdb]
enabled = true
apiKey = "your_api_key"
```

| Option | Description | Default |
|--------|-------------|---------|
| `enabled` | Enable OMDb API calls | `false` |
| `apiKey` | Your OMDb API key | (required when enabled) |
| `timeoutSeconds` | API request timeout | `5` |
| `poster.enabled` | Embed movie poster | `true` |
| `display.plot` | Show plot summary | `false` |
| `display.plotMaxLength` | Max characters for plot | `150` |

> **Note:** Ratings, genre, runtime, and season count are always displayed when available — these are core metadata that users expect to see.

**Graceful Degradation:** If metadata lookup fails (title mismatch, API timeout, quota exceeded), emails render normally without enrichment — the feature never blocks job completion.

---

## Mailozaurr (Recommended)

For inline poster images in emails, install [Mailozaurr](https://github.com/EvotecIT/Mailozaurr) v2.x:

```powershell
Install-Module Mailozaurr -AllowPrerelease
```

Without Mailozaurr, Stagearr falls back to the deprecated `Send-MailMessage` cmdlet which doesn't support inline images (CID attachments) or implicit SSL (port 465).
