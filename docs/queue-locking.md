# Job Queue & Locking

Stagearr uses a file-backed job queue with a global lock to ensure only one worker processes jobs
at a time. This design makes it safe to run Stagearr from qBittorrent (or multiple machines
sharing a network drive) without risk of concurrent imports or data corruption.

## Job Queue

Jobs are stored as JSON files in subdirectories under `paths.queueRoot`. Each job moves through
states in order:

```
pending -> running -> completed
                   -> failed
```

The directory layout on disk:

```
Queue/
  pending/      # Jobs waiting to be processed (FIFO order)
  running/      # Job currently being processed (at most one)
  completed/    # Successfully finished jobs
  failed/       # Jobs that encountered errors
  .lock         # Global lock file (JSON)
```

When qBittorrent triggers Stagearr, a job is added to `pending/`. The worker picks up pending
jobs one at a time, moves each through `running/` and into `completed/` or `failed/`.

**Deterministic job IDs.** Each job ID is derived from the download path and torrent hash. This
prevents duplicates: submitting the same torrent twice results in the second submission being
silently skipped (unless `-Force` is used).

**Orphan recovery.** If a worker crashes mid-job, the job file is left in `running/`. The next
worker to acquire the lock detects and moves any orphaned `running/` jobs back to `pending/`
automatically before it starts processing.

**Retry scheduling.** Jobs can carry a `retryAfter` timestamp. The worker skips them until that
time arrives (used internally for TBA-episode retries in Sonarr).

## Global Lock

The `.lock` file prevents concurrent workers from processing jobs simultaneously. Only one worker
holds the lock at a time. A worker that cannot acquire the lock exits immediately and leaves its
job in the queue; the active worker processes all queued jobs before releasing the lock.

### Lock file contents

The lock file is a JSON document with:

| Field | Description |
|-------|-------------|
| `pid` | Process ID of the lock holder |
| `processStartTimeUnix` | Process start time (Unix seconds). Guards against PID reuse on Windows. |
| `hostname` | Machine name. Identifies the holder in multi-machine setups. |
| `startedAt` | ISO 8601 timestamp when the lock was acquired |
| `heartbeatAt` | UTC timestamp refreshed periodically by a background runspace |
| `version` | Lock format version (current: 4) |

### Heartbeat-based liveness (v2.7.0)

As of v2.7.0 the lock is **heartbeat-based**. While the lock is held, a background runspace
refreshes `heartbeatAt` every `processing.heartbeatSeconds` seconds (default: 30). Another
worker may take the lock only after the heartbeat has been silent for at least
`processing.staleHeartbeatSeconds` seconds (default: 120).

This replaced an older timeout-only approach that could steal the lock from a live worker during
a long but legitimate pause (such as a slow subtitle download or large import poll).

Config keys (in the `[processing]` section, see [Settings Reference](settings-reference.md)):

```toml
[processing]
heartbeatSeconds = 30        # How often the active worker refreshes the lock
staleHeartbeatSeconds = 120  # Grace period before another worker may take the lock
```

### Stale lock recovery

A lock is considered stale when:

- **Same machine:** The lock-holding PID is no longer alive. A dead PID is treated as stale
  immediately, regardless of heartbeat age. Process start time is validated to prevent false
  positives from PID reuse.
- **Remote machine:** PID liveness cannot be checked across machines. Staleness is determined
  solely by heartbeat age: if `heartbeatAt` has not been updated for more than
  `staleHeartbeatSeconds`, the lock is considered stale.

When a stale lock is detected, the recovering worker takes the lock using an atomic
compare-and-swap rename. If two workers race to recover the same stale lock, exactly one wins;
the other retries.

A diagnostic log (`.lock-diagnostic.log` in `queueRoot`) records all lock events for
troubleshooting.

### Import ownership guard

At the point of sending files to Radarr or Sonarr, Stagearr re-verifies that it still owns
the lock. If another worker has taken over (for example, the original worker was presumed dead
due to a long pause and the lock was legitimately stolen), the import is aborted rather than
risking a double import. Phase boundaries between major processing steps also check for lock
theft and abort the job early. See [Importing](importing.md) for how this interacts with the
import flow.

## Running from Multiple Machines

Stagearr supports multi-machine operation when all instances share the same `queueRoot`
directory (for example, via a network share or NAS). The lock system is hostname-aware:

- The lock file includes the hostname of the holder.
- Status output identifies which machine holds the lock (e.g., `Already held by SERVER2 (PID 1234)`).
- Stale detection for remote locks uses heartbeat age. Clocks on all participating machines must
  be NTP-synchronized; the `staleHeartbeatSeconds` comment in `config-sample.toml` says this
  explicitly.

**Requirements for multi-machine operation:**

1. **Shared `queueRoot`.** All instances must point to the same queue directory on shared storage.
2. **Shared `stagingRoot`.** All instances must write to the same staging location, or use
   `paths.remotePath` mapping so importers can find the files.
3. **Atomic file operations.** The queue directory must be on a filesystem that supports atomic
   file creation (NTFS and SMB shares qualify).

Multiple machines do not process jobs in parallel. They take turns: if Machine A holds the lock,
Machine B's worker enqueues its job and exits. Machine A processes all queued jobs (including
Machine B's) before releasing the lock.

Use `.\Stagearr.ps1 -Status` to see which machine currently holds the lock and what job is
being processed.
