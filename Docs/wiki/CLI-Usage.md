# CLI Usage

## Quick Start

```powershell
# First-time setup
.\Stagearr.ps1 -Setup

# Process a download
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie"

# Check queue status
.\Stagearr.ps1 -Status
```

---

## qBittorrent Hook

Set this as the "Run external program on torrent finished" command in qBittorrent:

```
powershell -ExecutionPolicy Bypass -File "C:\Stagearr\Stagearr.ps1" -DownloadPath "%F" -DownloadLabel "%L" -TorrentHash "%I"
```

Each torrent completion enqueues a job and starts processing. If another job is already running, the new job waits in the queue and is processed automatically when the current one finishes.

---

## Parameters

### Processing

| Parameter | Description |
|-----------|-------------|
| `-DownloadPath` | Path to the downloaded torrent file or folder. Required for processing. |
| `-DownloadLabel` | Torrent label/category (e.g., `TV`, `Movie`). Maps to content type via config. Defaults to `NoLabel` if empty. |
| `-TorrentHash` | Torrent info hash. Used for *arr import matching and duplicate detection. |

### Modifiers

| Parameter | Description |
|-----------|-------------|
| `-Wait` | Wait for the lock if another instance is currently processing. Without this, the script exits immediately if the lock is held (the job is still queued and will be picked up). Useful for manual runs when you want to see console output. |
| `-NoCleanup` | Keep the staging folder after processing instead of cleaning up. Useful for debugging. |
| `-SkipEmail` | Skip email notification for this job. Also aliased as `-NoMail`. |
| `-Force` | Re-run a job that already exists (completed or failed). Without this, duplicate jobs are skipped. |

### Utilities

| Parameter | Description |
|-----------|-------------|
| `-Status` | Show queue status: pending/running/completed/failed counts, lock holder, recent job details. |
| `-Setup` | Run the interactive setup wizard to create or edit `config.toml`. |
| `-SyncConfig` | Compare your `config.toml` against `config-sample.toml` and report missing or extra settings. Useful after updating Stagearr. |

### Advanced

| Parameter | Description |
|-----------|-------------|
| `-ConfigPath` | Path to an alternate `config.toml` file. Defaults to the same directory as the script. |
| `-Verbose` | Show detailed output: tool versions, API requests/responses, processing decisions, error context. |

---

## Examples

```powershell
# Manual processing with all options
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -TorrentHash "ABC123"

# Re-run a failed job
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -Force

# Process manually while qBittorrent worker is active (wait for lock)
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -Wait

# Test run without sending email
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -SkipEmail

# Debug with verbose output
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -Verbose

# Check what's in the queue
.\Stagearr.ps1 -Status

# Check for new config settings after update
.\Stagearr.ps1 -SyncConfig
```
