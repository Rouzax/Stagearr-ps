# CLI Usage & Parameters

Stagearr is driven from the command line. All invocations go through `Stagearr.ps1`, which accepts
parameter sets that map to distinct modes of operation.

## Quick Start

```powershell
# First-time setup
.\Stagearr.ps1 -Setup

# Process a download manually
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie"

# Check queue status
.\Stagearr.ps1 -Status
```

## Parameter Sets

Stagearr uses PowerShell parameter sets. Each set is mutually exclusive: you run in one mode per
invocation. The default mode (no mode switch) is **Enqueue**.

### Enqueue (default)

Adds a job to the queue and starts processing. This is the mode qBittorrent uses.

| Parameter | Type | Description |
|-----------|------|-------------|
| `-DownloadPath` | string | Path to the completed torrent file or folder. Required. |
| `-DownloadLabel` | string | Torrent label/category (e.g., `TV`, `Movie`). Maps to content type via [label config](labels.md). Defaults to `NoLabel` if omitted or blank. |
| `-TorrentHash` | string | Torrent info hash. Used for import matching and duplicate detection. |
| `-NoCleanup` | switch | Keep the staging folder after processing instead of deleting it. Useful for debugging. |
| `-SkipEmail` | switch | Skip email notification for this job. Also accepted as `-NoMail`. |
| `-Force` | switch | Re-run a job that already exists in completed or failed state. Without this flag, duplicate jobs are silently skipped. |
| `-Wait` | switch | Wait for the global lock if another instance is currently processing. Without this, the script exits immediately if the lock is held (the job is still queued and will be picked up by the active worker). Useful for manual runs when you want to see console output. |

### Status

Shows queue status: pending/running/completed/failed counts, lock holder, and recent job details.

```powershell
.\Stagearr.ps1 -Status
```

### SyncConfig

Compares your `config.toml` against `config-sample.toml` and reports missing or extra settings.
Run this after updating Stagearr to catch any new configuration keys.

```powershell
.\Stagearr.ps1 -SyncConfig
```

### Setup

Runs the interactive setup wizard to create or edit `config.toml`.

```powershell
.\Stagearr.ps1 -Setup
```

### Update

Checks for updates and applies them if available. The behavior depends on the `updates.mode`
setting in your config. See [Auto-Update](updates.md) for the full update mechanism.

```powershell
.\Stagearr.ps1 -Update
```

### Rerun

Interactively re-runs a recent completed or failed job. Shows a numbered list, prompts for a
selection, and re-dispatches the job with `-Force -Wait`. See [Re-running Jobs](rerun.md) for
details.

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Rerun` | switch | Enter the re-run selector. |
| `-RerunLimit` | int | Number of recent jobs to show in the list. Default: `10`. |

```powershell
.\Stagearr.ps1 -Rerun
.\Stagearr.ps1 -Rerun -RerunLimit 20
```

### ConfigPath (global)

`-ConfigPath` is available in all parameter sets. It specifies an alternate path to `config.toml`.
By default, Stagearr looks in the same directory as the script.

```powershell
.\Stagearr.ps1 -Status -ConfigPath "D:\Config\stagearr.toml"
```

## Common Parameter: -Verbose

`-Verbose` is a standard PowerShell common parameter (not specific to any parameter set). It
enables detailed output: tool versions, API requests and responses, processing decisions, and
error context.

```powershell
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -Verbose
```

## qBittorrent Hook

Set this as the "Run external program on torrent finished" command in qBittorrent:

```
powershell -ExecutionPolicy Bypass -File "C:\Stagearr\Stagearr.ps1" -DownloadPath "%F" -DownloadLabel "%L" -TorrentHash "%I"
```

Each torrent completion enqueues a job and starts processing. If another job is already running,
the new job waits in the queue and is processed automatically when the current one finishes.

For full qBittorrent setup instructions, see [qBittorrent Integration](qbittorrent.md).

## Examples

```powershell
# Process a download (qBittorrent style)
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -TorrentHash "ABC123"

# Re-run a failed job without deleting staging files
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -Force -NoCleanup

# Process manually while the background worker is active (wait for the lock)
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -Wait

# Test run without sending email
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -SkipEmail

# Debug with verbose output
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -Verbose

# Check what is in the queue
.\Stagearr.ps1 -Status

# Check for new config settings after an update
.\Stagearr.ps1 -SyncConfig

# Interactively re-run a recent job
.\Stagearr.ps1 -Rerun

# Show the last 20 jobs for re-run selection
.\Stagearr.ps1 -Rerun -RerunLimit 20

# Check for and apply updates
.\Stagearr.ps1 -Update
```
