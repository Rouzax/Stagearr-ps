# Importing to Radarr / Sonarr / Medusa

After video and subtitle processing, Stagearr submits the staged files to your media server. This page explains how the dispatcher decides which importer to use, how the ManualImport flow works, and what to configure for remote path translation.

---

## Prerequisites

Before importing works, the target application must be reachable from the machine running Stagearr:

- **Radarr** (movies): enable `[importers.radarr]` and provide `host`, `port`, and `apiKey`
- **Sonarr** (TV): enable `[importers.sonarr]` and provide `host`, `port`, and `apiKey`
- **Medusa** (TV, alternative): enable `[importers.medusa]` and set `processing.tvImporter = "Medusa"`

The API key for Radarr and Sonarr is found under Settings > General > Security in each application.

---

## Dispatch: Which Importer Runs

The dispatcher in `Import.ps1` checks the download label against your configured label lists and routes the job accordingly.

| Label type | Importer |
|-----------|---------|
| Movie label | Radarr |
| TV label, `tvImporter = "Sonarr"` (default) | Sonarr |
| TV label, `tvImporter = "Medusa"` | Medusa |

The dispatch rule for TV is:

```toml
[processing]
tvImporter = "Sonarr"   # Sonarr | Medusa
```

When `tvImporter = "Medusa"` and `importers.medusa.enabled = true`, TV jobs go to Medusa. Otherwise, TV jobs go to Sonarr (when `importers.sonarr.enabled = true`). If neither importer is enabled and configured, the import is skipped with a warning.

Movie jobs always go to Radarr. There is no alternative movie importer.

If the label does not match any configured TV or movie label, the import is skipped (the job still succeeds; this is the expected passthrough behavior for unknown labels).

See [Labels and Content Routing](labels.md) for how labels are configured.

---

## ManualImport Flow

Both Radarr/Sonarr and Medusa use the ManualImport API. The flow is the same for all importers:

### Step 1: Scan

Stagearr calls the ManualImport scan endpoint, pointing it at the staging folder. The API returns a list of files with metadata (title, year, quality, season/episode for TV) and any rejection reasons.

For Radarr and Sonarr, if the scan could not match files to a library entry (for example, due to a misspelled release name), Stagearr uses the cached queue or history records from the Initialize phase to inject the correct identity before filtering.

### Step 2: Filter

Stagearr separates the scan results into importable files and rejected files. Rejections fall into two categories:

- **Permanent rejections**: the file should not be imported (wrong quality, already exists with better quality)
- **Importable files**: cleared to proceed

If all files are rejected, the job reports a skip with the rejection reason. Partial rejections (some files importable, some rejected) result in a partial import with a warning in the email.

### Step 3: Execute

Stagearr sends the importable files to the ManualImport execute endpoint. This triggers the actual file operation (move or copy, depending on `importMode`) and the library update.

```toml
[importers.radarr]
importMode = "move"   # move | copy
```

### Step 4: Poll

After executing, Stagearr polls the command API until the import completes or the timeout is reached. The timeout is configurable:

```toml
[importers.radarr]
timeoutMinutes = 10
```

### TBA (To Be Announced) handling

For Sonarr imports, if an episode title is still TBA in the database, Sonarr rejects the import. When this happens, Stagearr:

1. Attempts a metadata refresh on the series to pull in any updated titles
2. Re-scans after the refresh
3. If still TBA, schedules an automatic retry approximately 48 hours later (staged files are kept until the retry runs)

The email for the original job shows "Pending retry". The retry email shows the final import result.

---

## Lock Ownership Guard

At the point of executing the import, Stagearr checks that it still holds the global processing lock. If another worker took the lock during a long pause (for example, the original worker was presumed dead due to a slow subtitle download), the import is aborted rather than risking a double import.

This check is in addition to the phase-boundary checks that run between Video, Subtitles, and Import.

See [Job Queue and Locking](queue-locking.md) for how the global lock works.

---

## Remote Path Mapping

When Stagearr runs on a different machine from the media server, the path to the staging folder as seen by Stagearr and the path as seen by the importer will differ. Use `remotePath` to translate:

```toml
[importers.radarr]
remotePath = "\\\\NAS\\Staging"
```

When `remotePath` is set, Stagearr replaces the local `paths.stagingRoot` prefix with `remotePath` before calling the ManualImport API. The importer sees the path from its own perspective.

Example: if Stagearr stages to `C:\Staging\Movie\Film.2024` and the importer sees the same location as `\\NAS\Staging\Movie\Film.2024`, set `remotePath = "\\\\NAS\\Staging"`.

---

## Configuration Reference

Full configuration for all importers:

```toml
[importers.radarr]
enabled = true
host = "localhost"
port = 7878
apiKey = "your_radarr_api_key"
ssl = false
urlRoot = ""          # Set if behind a reverse proxy (e.g., "/radarr")
timeoutMinutes = 10
remotePath = ""       # Leave empty if Stagearr and Radarr share the same file paths
importMode = "move"   # move | copy

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

For all available settings and their defaults, see the [Settings Reference](settings-reference.md).
