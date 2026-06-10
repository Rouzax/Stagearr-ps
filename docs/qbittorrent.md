# qBittorrent Integration

## Purpose

qBittorrent can run an external program each time a torrent finishes downloading. Stagearr uses this hook to start processing automatically, without any manual intervention. When a torrent completes, qBittorrent calls Stagearr with the torrent's save path, label, and hash; Stagearr enqueues a job and begins processing.

---

## Setting up the completion hook

1. Open qBittorrent.
2. Go to **Tools > Options > Downloads**.
3. Enable **Run external program on torrent finished**.
4. Paste the following command, replacing `C:\Stagearr-ps` with your actual installation path:

```
powershell.exe -ExecutionPolicy Bypass -File "C:\Stagearr-ps\Stagearr.ps1" -DownloadPath "%F" -DownloadLabel "%L" -TorrentHash "%I"
```

5. Click **OK** to save.

qBittorrent substitutes the placeholders at runtime:

| Placeholder | Value passed to Stagearr |
|-------------|--------------------------|
| `%F` | Full save path of the completed torrent (file or folder) |
| `%L` | Torrent category/label |
| `%I` | Torrent info hash |

These map to the `-DownloadPath`, `-DownloadLabel`, and `-TorrentHash` parameters of `Stagearr.ps1`.

---

## What happens when a torrent completes

The hook invocation uses the **Enqueue** parameter set. Stagearr writes a job entry to the file-backed queue and then attempts to acquire the global processing lock.

- If no other job is running, Stagearr acquires the lock and processes the job immediately.
- If another job is already running, the new job is saved to the queue and the hook exits. The active worker picks up the queued job as soon as it finishes its current one.

This means multiple torrent completions are handled safely, even when they arrive at the same time. No jobs are lost and no two jobs run concurrently.

For details on how the queue and lock work, including how Stagearr handles lock expiry and worker failures, see [Job Queue and Locking](queue-locking.md).

---

## Assign labels in qBittorrent

Stagearr uses the torrent's label (called a "category" in qBittorrent) to decide how to process each download. A label of `Movie` routes to Radarr; a label of `TV` routes to Sonarr or Medusa; unknown labels trigger passthrough mode (extract and copy only, no import).

Set the category on each torrent before or at the time you add it to qBittorrent. You can also set a default category per tracker in qBittorrent's settings.

See [Labels and Content Routing](labels.md) for the full list of recognized labels and how to customize them.

---

## Verifying the hook

After saving the qBittorrent setting, you can verify the integration without waiting for a real torrent to finish:

1. Run a test invocation from a PowerShell prompt, substituting a real download path and label:

    ```powershell
    .\Stagearr.ps1 -DownloadPath "C:\Downloads\Test.Movie.2024" -DownloadLabel "Movie" -SkipEmail
    ```

2. Check the result:

    ```powershell
    .\Stagearr.ps1 -Status
    ```

`-Status` prints queue contents and recent job outcomes. A successful run appears in the completed list. See [Quick Start: Check queue status](quick-start.md#step-3-check-queue-status) for a full description of the output.
