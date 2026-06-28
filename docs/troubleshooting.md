# Troubleshooting & FAQ

This page organizes problems by what you see, then answers common setup questions. If you are reading a log file or email notification that mentions a specific phase, check the relevant page ([Pipeline Overview](pipeline.md), [Importing](importing.md), [Subtitles](subtitles.md)) for phase-specific detail.

---

## Troubleshooting

### Checking queue and job status

Run this first when something looks wrong:

```powershell
.\Stagearr.ps1 -Status
```

The output shows:

- Pending, running, completed, and failed job counts
- Lock status and which machine holds it (including PID and hostname)
- Any running job with its current phase, activity, and elapsed time
- Recent completed and failed jobs with duration and error messages

This tells you whether a worker is actively processing, whether the lock is held by a live or stale process, and what happened to recent jobs.

---

### Enabling verbose output

Add the PowerShell common parameter `-Verbose` to any processing run:

```powershell
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie" -DownloadLabel "Movie" -Verbose
```

With `-Verbose` you will see:

- Detected tool versions and resolved paths
- Full API request and response bodies for Radarr/Sonarr calls
- Detailed subtitle analysis (which tracks exist, which are kept, which are stripped)
- Error context when something goes wrong

Verbose output goes to the console only; it is not included in the saved log file.

---

### Log files

Completed job logs are saved to the directory configured as `paths.logArchive`. Filenames follow this format:

```
YYYY-MM-DD HH.mm.ss-friendly-name.log
```

Example: `2026-01-01 15.24.21-Wake Up Dead Man (2025).log`

Each log starts with a header that shows the parsed release metadata (title, quality, group, label, torrent hash, and source path), plus the detected tool versions. Reading the header quickly tells you what Stagearr understood about the download before processing started.

For passthrough jobs (unknown labels such as ebooks or software), the Quality and Group fields are omitted because no media metadata is parsed.

---

### Cannot connect to Radarr or Sonarr

- Verify `host`, `port`, and `apiKey` in the `[importers.radarr]` or `[importers.sonarr]` section.
- Confirm the service is running and reachable from the machine running Stagearr.
- If the service is behind a reverse proxy with a URL prefix (for example, `/radarr`), set `urlRoot` accordingly.
- Use `-Verbose` to see the exact URL Stagearr is requesting and the HTTP error response.

---

### Import rejected or skipped

When an import is rejected, check the *arr app's Activity > Queue view for the rejection reason. Stagearr also logs rejection reasons in the console and in verbose output.

Common causes:

- **Quality cutoff already met:** the library already has a copy that meets or exceeds the configured quality profile cutoff. This is a permanent rejection; Stagearr will not import a lower-quality replacement.
- **File not matched:** the release name could not be parsed to a library entry. Check that the torrent name is standard and that the movie or series exists in your library.
- **Wrong category:** the import was routed to the wrong *arr app. Verify your label configuration. See [Labels & Content Routing](labels.md).

If all scan results are rejected, the job ends with a skip. If only some are rejected, Stagearr imports the accepted files and warns about the others.

---

### Radarr or Sonarr imported the raw download before Stagearr processed it

This is the most common setup mistake. If both Stagearr and your *arr app are watching the same download folder, the *arr app auto-imports the original torrent files before Stagearr has a chance to remux, strip subtitle tracks, or clean subtitles.

The fix is described on the [Importing](importing.md#prevent-radarrsonarr-from-auto-importing) page. In short, you must prevent the *arr app from monitoring the download folder directly, either by pointing its download client settings at an empty folder or by disabling Completed Download Handling.

---

### Episode title TBA (Sonarr)

Sonarr rejects imports when an episode title is still listed as "TBA" in its database. Stagearr handles this automatically:

1. It refreshes the series metadata in Sonarr and re-scans.
2. If the title is still TBA, it schedules a retry approximately 49 hours later. Staged files are kept until the retry runs.
3. The email for the original run shows `Import: Pending retry` with the expected retry date. The retry run sends its own separate email.
4. If the retry also fails (for example, Sonarr is unreachable), no further automatic retries are scheduled. Use `-Rerun` to try again manually.

---

### Lock held / job appears stuck

Run `.\Stagearr.ps1 -Status` to see what is holding the lock and whether it is still live.

The lock is heartbeat-based (introduced in v2.7.0). While a worker is active, it writes a fresh timestamp to the lock file every `processing.heartbeatSeconds` seconds (default: 30). If no heartbeat has arrived for more than `processing.staleHeartbeatSeconds` (default: 120), the next worker will take the lock automatically. No manual intervention is needed.

On the same machine, Stagearr also checks whether the lock-holding PID is still running. A dead process is treated as stale immediately, regardless of heartbeat age.

If you are running manually while another worker is active, add `-Wait` to wait for the lock instead of exiting:

```powershell
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie" -DownloadLabel "Movie" -Wait
```

See [Job Queue & Locking](queue-locking.md) for a full description of the lock mechanism and multi-machine operation.

---

### Orphaned job left in the running state

If Stagearr was interrupted mid-job (power loss, process kill, reboot), the job file is left in the `running/` folder inside `queueRoot`. The next time any worker acquires the lock, it automatically moves orphaned running jobs back to `pending/` before it starts processing. No manual intervention is needed.

---

### Files not recognized or passthrough mode activated

If a job completes but nothing was imported, the label most likely did not match any configured TV or movie label. Check the log header: the `Label` field shows exactly what label was passed in.

Compare that label against the `[labels]` section of your `config.toml`. Matching is case-insensitive. If the label is not in `labels.tv`, `labels.tvLabels`, `labels.movie`, or `labels.movieLabels`, the job runs in passthrough mode: RAR extraction and copy occur, but no video processing or import happens.

See [Labels & Content Routing](labels.md) for how to configure label mappings.

---

### Path not accessible or staging failed

- If Stagearr and the *arr app run on different machines, configure `remotePath` in the importer section so the *arr app receives the path from its own perspective. See [Importing](importing.md#remote-path-mapping).
- Verify that the account running Stagearr has read access to the download path and write access to `paths.stagingRoot`.
- On network shares, confirm the share is mounted before Stagearr runs.

---

### Subtitle extraction failed or no subtitles found

- Verify that MKVToolNix is installed and that `tools.mkvextract` points to the correct binary.
- Only text-based subtitle formats can be extracted (SRT, WebVTT, ASS). Image-based formats (PGS, VobSub) stay in the MKV and cannot be extracted to SRT.
- Check `subtitles.wantedLanguages`. Stagearr only extracts tracks for languages in that list.

---

### Subtitle tracks not stripped (when expected)

- Check `subtitles.wantedLanguages` in `config.toml`.
- If none of your wanted languages are found in the MKV, all tracks are preserved. This protection prevents accidentally removing all subtitles when track language tags are missing or non-standard.
- Tracks matching `namePatternsToRemove` (such as "Forced") are only removed when a clean alternative in the same language exists.
- Run with `-Verbose` to see the subtitle track analysis and which decision was applied to each track.

See [Subtitle Processing](subtitles.md) for a full explanation of extraction, stripping, and the protection rules.

---

### Email not sent or SMTP timeout

- Check `smtp.server` and `smtp.port` in `config.toml`.
- For Gmail, use an [App Password](https://support.google.com/accounts/answer/185833) rather than your regular account password.
- Port 465 (implicit SSL) requires the [Mailozaurr](https://github.com/EvotecIT/Mailozaurr) module. Without it, use port 587 (STARTTLS).
- To test a run without sending email, add `-SkipEmail` (also aliased as `-NoMail`):

```powershell
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie" -DownloadLabel "Movie" -SkipEmail
```

---

### MDBList: Not marked (non-fatal)

This warning appears in the console and email when MDBList collection sync is enabled but the API call did not succeed. The import itself completed normally; this is a best-effort, non-fatal step.

Common causes and fixes:

| Symptom / cause | Fix |
|-----------------|-----|
| Invalid or empty API key | Check `mdblist.apiKey` in `config.toml`. Retrieve your key from [mdblist.com/preferences/](https://mdblist.com/preferences/) under the API section. |
| No internet access or MDBList is unavailable | Confirm the machine running Stagearr can reach `api.mdblist.com`. Try again later if MDBList is experiencing an outage. |
| Item has no tmdb, tvdb, or imdb ID | The Radarr or Sonarr import response did not include a usable ID. Verify that the movie or episode is correctly matched in your media server. |

Run with `-Verbose` to see the full HTTP response from MDBList and confirm which error was returned.

See [MDBList Collection Sync](mdblist.md) for setup instructions and expected console output.

---

### MDBList: collected items reappear on my "not collected" list

Titles you imported and marked collected come back onto a title-level "not collected" list after a day or two. This is caused by MDBList's **Trakt collection sync** re-importing your Trakt collection and overwriting MDBList's own, which prunes anything not in Trakt (and Trakt's free collection cap can prevent new titles from being added there at all).

Fix: in MDBList, **Preferences → Trakt**, turn off **"Trakt Sync (Watchlist, Watched, Ratings, Library)"** and Save, then re-mark your library once. See [MDBList Collection Sync → Troubleshooting](mdblist.md#items-i-marked-keep-reappearing-on-my-not-collected-list) for the full explanation and trade-offs.

---

## FAQ

### Which external tools do I actually need?

It depends on which features you enable. The only tool required for all installs is WinRAR (RAR extraction is always active). Everything else is conditional:

| Tool | Required when |
|------|--------------|
| WinRAR | Always |
| MKVToolNix (mkvmerge) | MP4 remux or subtitle stripping is enabled |
| MKVToolNix (mkvextract) | Subtitle extraction is enabled |
| SubtitleEdit | Subtitle cleanup is enabled |

If you disable a feature in `config.toml`, you do not need to install its tool. See [Installation](installation.md) for download links and [Settings Reference](settings-reference.md#tools) for the path keys.

---

### Why is my download running in passthrough mode?

The torrent's label did not match any TV or movie label in your configuration. In passthrough mode, Stagearr extracts any RAR archives and copies files to the staging folder, but skips video processing and import.

Check the `Label` field in the log file header and compare it against your `[labels]` section in `config.toml`. See [Labels & Content Routing](labels.md) to configure which labels route to which pipeline.

---

### Why did Radarr/Sonarr import the raw files before Stagearr processed them?

Radarr and Sonarr both monitor the download client for completed downloads and import them automatically if Completed Download Handling is active. When Stagearr is also processing the same downloads, the *arr app races it and wins, importing unprocessed files.

The solution is to stop the *arr app from monitoring your download folder directly. See [Importing](importing.md#prevent-radarrsonarr-from-auto-importing) for the two recommended options (point the download client at an empty folder, or disable Completed Download Handling).

---

### What does "lock held" or "another worker is processing" mean?

Only one Stagearr worker can process jobs at a time. When a second instance starts while the first is running, it enqueues its job and exits. The active worker processes all pending jobs (including the newly added one) before releasing the lock.

The lock uses a heartbeat: the active worker refreshes a timestamp in the lock file every 30 seconds (configurable). If no refresh arrives for 120 seconds, the lock is considered stale and the next worker takes it. This handles crashes and reboots automatically.

See [Job Queue & Locking](queue-locking.md) for details on the lock file, stale detection, and multi-machine setups.

---

### How do I re-run a failed job?

Use the interactive `-Rerun` selector:

```powershell
.\Stagearr.ps1 -Rerun
```

This lists recent completed and failed jobs. Enter a number to select one, confirm, and Stagearr re-runs it with full console output. Pass `-RerunLimit 20` to see more history (default is 10).

See [Re-running Jobs](rerun.md) for full details, including cross-server path translation.

---

### How do I update, and will it overwrite my config?

```powershell
.\Stagearr.ps1 -Update
```

This checks GitHub for a new release and applies it. Your `config.toml`, queue data, and log files are not touched: the release ZIP contains only the runtime files (`Stagearr.ps1`, `Modules/`, `config-sample.toml`, `LICENSE`, `README.md`).

After updating, check whether new configuration keys were added:

```powershell
.\Stagearr.ps1 -SyncConfig
```

`-SyncConfig` compares your `config.toml` against the updated `config-sample.toml` and lists any missing or extra keys. See [Auto-Update](updates.md) for update modes and the background check interval.
