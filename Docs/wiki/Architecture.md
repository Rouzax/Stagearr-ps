# Architecture

## Module Structure

```
Stagearr-ps/
├── Stagearr.ps1              # CLI entrypoint
├── config-sample.toml             # Sample configuration (TOML)
├── config.toml                    # Your configuration (not tracked)
├── Modules/
│   └── Stagearr.Core/
│       ├── Stagearr.Core.psd1    # Module manifest
│       ├── Stagearr.Core.psm1    # Module loader
│       ├── Private/                    # Internal helpers
│       │   ├── Output/                # Output/rendering subsystem
│       │   │   ├── ConsoleRenderer.ps1
│       │   │   ├── EmailHelpers.ps1
│       │   │   ├── EmailRenderer.ps1
│       │   │   ├── EmailSections.ps1
│       │   │   ├── EmailSubject.ps1
│       │   │   ├── FileLogRenderer.ps1
│       │   │   └── OutputEvent.ps1
│       │   ├── ArrMetadata.ps1        # Extract metadata from *arr APIs
│       │   ├── Config.ps1             # Configuration management
│       │   ├── ConfigSync.ps1         # Config sync utility
│       │   ├── Constants.ps1          # Centralized constants
│       │   ├── Context.ps1            # Job context management
│       │   ├── ErrorHandling.ps1      # User-friendly errors
│       │   ├── EpisodeFormatting.ps1   # Episode display formatting
│       │   ├── FileIO.ps1             # File I/O operations
│       │   ├── Formatting.ps1         # General formatting utilities
│       │   ├── Http.ps1               # HTTP client with retry
│       │   ├── ImportResultParser.ps1  # API response parsing
│       │   ├── ImportUtility.ps1       # URL/path utilities
│       │   ├── Language.ps1           # ISO 639 language codes
│       │   ├── MediaDisplay.ps1       # Quality/source display
│       │   ├── MediaParsing.ps1       # Release name parsing
│       │   ├── MkvAnalysis.ps1        # Video track analysis
│       │   ├── Omdb.ps1               # OMDb API client
│       │   ├── PathSecurity.ps1       # Path traversal prevention
│       │   ├── Process.ps1            # External tool execution
│       │   ├── Toml.ps1               # TOML parser
│       │   └── Utility.ps1            # Common utilities
│       └── Public/                     # Exported API
│           ├── Import.ps1             # Import dispatcher
│           ├── ImportArr.ps1          # Radarr/Sonarr integration
│           ├── ImportMedusa.ps1       # Medusa integration
│           ├── JobProcessor.ps1       # Job orchestration
│           ├── Lock.ps1               # Global mutex
│           ├── Notification.ps1       # Email sending
│           ├── OpenSubtitles.ps1      # OpenSubtitles API
│           ├── Queue.ps1              # Job queue CRUD
│           ├── RarExtraction.ps1      # RAR archive handling
│           ├── Setup.ps1              # Interactive setup wizard
│           ├── Staging.ps1            # Staging operations
│           ├── SubtitleProcessing.ps1  # Subtitle handling
│           └── Video.ps1              # Video processing
└── Docs/
    ├── FUNCTION-REFERENCE.md          # Developer reference
    └── OUTPUT-STYLE-GUIDE.md          # Output design guide
```

---

## Processing Pipeline

The main orchestrator is `Invoke-SAJobProcessing` in `Public/JobProcessor.ps1`. It runs phases in order:

```
1. Initialize    → Load config, create context, initialize output system
2. Stage         → Copy/extract files to staging folder
3. Video         → RAR extraction, MP4 remux, subtitle track stripping
4. Subtitles     → Extract from MKV, download from OpenSubtitles, clean with SubtitleEdit
5. Import        → Send to Radarr/Sonarr/Medusa, poll for completion
6. Notify        → Save log file, send email notification
```

---

## Entrypoint and Module System

`Stagearr.ps1` is the CLI entrypoint. It imports the `Stagearr.Core` PowerShell module from `Modules/Stagearr.Core/`. The module loader (`Stagearr.Core.psm1`) dot-sources files in a **strict dependency order** — do not rearrange without checking dependencies.

- **Private/** — Internal helpers, not exported. Loaded first.
- **Public/** — Exported functions listed in `Stagearr.Core.psd1`. Loaded second.
- All functions use the `SA` noun prefix (e.g., `Write-SAOutcome`, `Invoke-SAImport`).

---

## Output System

Stagearr uses an event-based output system that separates business logic from presentation:

| Renderer | Purpose |
|----------|---------|
| `ConsoleRenderer.ps1` | Real-time colored console output with Unicode markers |
| `FileLogRenderer.ps1` | Plain-text verbose log files for troubleshooting |
| `EmailRenderer.ps1` | HTML email state management |
| `EmailSections.ps1` | HTML section builders |
| `EmailSubject.ps1` | Subject line with template placeholders |
| `EmailHelpers.ps1` | Color palette, display helpers |

**Key contract:** Use `Write-SAOutcome`, `Write-SAPhaseHeader`, `Write-SAProgress`, `Write-SAKeyValue`, `Write-SAVerbose` etc. Never write directly to console from business logic.

See `Docs/OUTPUT-STYLE-GUIDE.md` for the full design philosophy and rules.

---

## Key Internal Helpers

| File | Purpose |
|------|---------|
| `MediaParsing.ps1` | Release name parsing (resolution, source, group, service) |
| `MediaDisplay.ps1` | Human-friendly source/service name formatting |
| `MkvAnalysis.ps1` | MKV track analysis for subtitle decisions |
| `ImportUtility.ps1` | URL building, hostname resolution, remote path mapping |
| `ImportResultParser.ps1` | API response parsing, error categorization, hints |
| `ArrMetadata.ps1` | Extract metadata from Radarr/Sonarr ManualImport results |
| `PathSecurity.ps1` | Path traversal and zip-slip prevention |
| `Http.ps1` | HTTP client with exponential backoff retry |
| `Language.ps1` | ISO 639-1/639-2 language code normalization |
| `Context.ps1` | Job context object creation (carries state through pipeline) |

---

## Import Pattern

`Public/Import.ps1` dispatches to `ImportArr.ps1` (Radarr/Sonarr) or `ImportMedusa.ps1` based on label + config. Both use the ManualImport API pattern: scan → execute → poll for completion.

---

## Key Conventions

- **Function naming:** PowerShell approved verbs + `TS` noun prefix
- **Feature flags:** Check with `Test-SAFeatureEnabled` before doing work
- **Error handling:** `ErrorHandling.ps1` translates technical errors to user-friendly messages
- **Constants:** All magic numbers and defaults in `Constants.ps1` (`$script:SAConstants`)
- **Configuration:** TOML config merged with `$script:SAConfigDefaults`, passed as hashtable through pipeline
- **Queue system:** File-backed JSON with states: pending → running → completed/failed. Global lock prevents concurrent processing. Orphaned jobs are automatically recovered.

---

## Queue and Locking

Stagearr uses a file-backed job queue with a global lock to ensure only one worker processes jobs at a time.

### Job Queue

Jobs are stored as JSON files in subdirectories of `paths.queueRoot`:

```
Queue/
├── pending/      # Jobs waiting to be processed (FIFO)
├── running/      # Job currently being processed
├── completed/    # Successfully finished jobs
├── failed/       # Jobs that encountered errors
└── .lock         # Global lock file (JSON)
```

When qBittorrent triggers Stagearr, a job is added to `pending/`. The worker picks up pending jobs one at a time, moves them through `running/` → `completed/` or `failed/`.

Jobs have deterministic IDs based on download path + torrent hash, preventing duplicates. If a worker crashes mid-job, the orphaned `running/` job is automatically recovered back to `pending/` when the next worker starts.

### Global Lock

The `.lock` file prevents concurrent workers from processing jobs simultaneously. It contains:

- **PID** and **process start time** — identifies the lock holder (start time prevents PID reuse false-positives on Windows)
- **Hostname** — identifies which machine holds the lock
- **Timestamp** — when the lock was acquired

**Stale lock recovery:** If a worker crashes or the machine reboots, the lock becomes stale. Stagearr detects this in two ways:

- **Same machine:** Checks if the lock-holding PID is still alive (with start time validation to catch PID reuse)
- **Cross-machine:** Cannot validate remote PIDs, so relies purely on the `processing.staleLockMinutes` timeout (default: 15 minutes)

A diagnostic log (`.lock-diagnostic.log`) records all lock events for troubleshooting.

### Running From Multiple Machines

Stagearr supports running from multiple machines **if they share the same `queueRoot` directory** (e.g., via a network share or NAS). The lock system is hostname-aware:

- Lock files include the hostname, so each machine knows whether a lock is local or remote
- Lock status messages show which machine holds the lock (e.g., `Already held by SERVER2 (PID 1234)`)
- Stale lock recovery uses timeout-only for remote locks (since PIDs can't be validated across machines)

**Requirements for multi-machine operation:**

1. **Shared `queueRoot`** — All instances must point to the same queue directory on shared storage
2. **Shared `stagingRoot`** — All instances must write to the same staging location (or use `remotePath` mapping so importers can find the files)
3. **Atomic file operations** — The queue directory must be on a filesystem that supports atomic file creation (NTFS, SMB shares — most do)

**Important:** The lock ensures only one worker runs at a time across all machines. Multiple machines don't process jobs in parallel — they take turns. If Machine A holds the lock, Machine B's worker exits immediately (or waits briefly if `-Wait` is used). This serialization is by design to avoid overwhelming the *arr apps with concurrent imports.

> **Tip:** Use `.\Stagearr.ps1 -Status` to see which machine currently holds the lock and what job is being processed.

---

## Security

- **Path Traversal Protection** — Validates all paths stay within allowed directories
- **Zip-Slip Prevention** — Pre-scans RAR contents before extraction, rejects malicious entries
- **Argument Escaping** — Safe external tool execution with proper quoting
- **Token Management** — Secure API token caching with expiry
- **Archive Validation** — Archives with dangerous patterns (`..\\`, absolute paths) are rejected
