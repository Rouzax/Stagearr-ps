# Re-running Jobs

The `-Rerun` flag opens an interactive selector that lets you pick a recent completed or failed
job and run it again. This is useful when:

- A job failed and you have fixed the underlying problem.
- An import was rejected and you want to retry it manually.
- You want to reprocess a download with different settings.

!!! note "Automatic TBA retries"
    Sonarr rejects episodes whose title is still listed as "TBA". Stagearr automatically
    schedules a retry 48 hours later for these cases. Use `-Rerun` only if the automatic
    retry also fails.

## Usage

```powershell
# Show the last 10 jobs and select one to re-run
.\Stagearr.ps1 -Rerun

# Show a longer list (last 20 jobs)
.\Stagearr.ps1 -Rerun -RerunLimit 20
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Rerun` | switch | | Opens the interactive job selector. |
| `-RerunLimit` | int | `10` | Number of recent jobs to show in the list. |

## What Happens

1. Stagearr fetches recent completed and failed jobs, sorted newest first.
2. A table is printed showing job number, state, date, label, and download name.
3. You enter a number to select a job, then confirm.
4. Stagearr re-dispatches the job with `-Force` (to allow re-running a finished job) and
   `-Wait` (to hold the console open until it finishes).

Example table output:

```
#    State      Date             Label      Name
--   -----      ----             -----      ----
1    completed  10-06-26 14:32   Movie      The.Movie.2024.MKV
2    failed     10-06-26 12:11   TV         Show.S01E03.HDTV
3    completed  09-06-26 22:05   Movie      Another.Film.2023
```

Enter `q` or press Enter without a number to cancel.

## Cross-Server Path Translation

When the queue is shared across multiple machines, the download path stored in the job was
recorded on the original machine. If the path is different on the current machine (for example,
drive letters differ), set `paths.downloadRoot` in your `config.toml`:

```toml
[paths]
downloadRoot = "D:\Downloads"
```

When `-Rerun` finds a job whose stored `downloadRoot` differs from the local one, it rewrites
the path by replacing the stored root with your local `downloadRoot`. This allows a job
originally queued on one server to be re-run from another.

If the download path no longer exists on disk (the source files were deleted after the original
import), Stagearr prints an error and cancels rather than attempting to process missing files.

## Related

- [CLI Usage & Parameters](cli-usage.md) for the full parameter reference.
- [Job Queue & Locking](queue-locking.md) for how jobs are stored and processed.
