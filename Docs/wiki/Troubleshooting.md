# Troubleshooting

## Check Queue Status

```powershell
.\Stagearr.ps1 -Status
```

Shows:
- Pending/Running/Completed/Failed job counts
- Lock status and holder info
- Running jobs with current phase, activity, and elapsed time
- Recent completed jobs with duration and finish time
- Recent failed jobs with error messages

---

## Enable Verbose Output

```powershell
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie" -DownloadLabel "Movie" -Verbose
```

Shows:
- Tool versions and paths
- API requests and responses
- Detailed processing steps
- Error context and stack traces

---

## Common Issues

### Cannot connect to Radarr/Sonarr

- Check `host` and `port` in config
- Verify API key is correct
- Ensure the service is running
- If behind a reverse proxy, set `urlRoot` (e.g., `/radarr`)

### Path not accessible

- Check `remotePath` mapping if using Docker/NAS
- Verify folder permissions
- Ensure network drives are mounted
- On Docker: the path Stagearr sees must be translated to the path the *arr app sees inside its container

### Subtitle extraction failed

- Verify MKVToolNix is installed
- Check `tools.mkvextract` path in config
- Only text subtitles (SRT, ASS, WebVTT) can be extracted — PGS/VobSub are image-based and stay in the MKV

### No subtitles stripped (when expected)

- Check `subtitles.wantedLanguages` in config
- **Protection rule:** If none of your wanted languages exist in the MKV, ALL tracks are preserved
- Tracks matching `namePatternsToRemove` are only removed if a clean alternative exists in the same language
- Use `-Verbose` to see subtitle analysis details

### Email send timed out

- Check SMTP server and port
- For Gmail, use an [App Password](https://support.google.com/accounts/answer/185833) — not your regular password
- Without Mailozaurr, port 465 (implicit SSL) is not supported — use port 587 instead
- Install [Mailozaurr](https://github.com/EvotecIT/Mailozaurr) v2.x for modern SMTP support

### Queue locked / job stuck

```powershell
# Check what's holding the lock
.\Stagearr.ps1 -Status
```

Orphaned jobs (from crashes/reboots) are automatically recovered when the next job runs. Stale locks (held longer than `processing.staleLockMinutes`) are automatically released. No manual intervention is needed — the next torrent completion or manual run will pick up any pending jobs.

If you're running manually and another instance is active, use `-Wait` to wait for the lock instead of exiting immediately:

```powershell
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie" -DownloadLabel "Movie" -Wait
```

### Import rejected by Radarr/Sonarr

- Check the *arr app's Activity > Queue for rejection reasons
- Common causes: quality cutoff already met, file not recognized, wrong category
- Use `-Verbose` to see the full API response including rejection reasons and hints

---

## Log Files

Log files are saved to `paths.logArchive` with naming:

```
YYYY-MM-DD HH.mm.ss-friendly-name.log
```

Example: `2026-01-01 15.24.21-Wake Up Dead Man (2025).log`

### Log Header

Each log starts with an enhanced header showing parsed release metadata:

```
================================================================================
Stagearr Job Log
================================================================================
Started:  2026-01-01 15:24:21
Title:    Wake Up Dead Man: A Knives Out Mystery (2025)
Quality:  2160p WEB-DL Dolby Vision
Group:    BYNDR
Label:    movie
Hash:     a1b2c3d4e5f6789012345678901234567890abcd
Source:   \\server\downloads\Wake.Up.Dead.Man.2025.2160p...

--- External Tools ---
MKVToolNix: 96.0 (C:\Program Files\MKVToolNix\mkvmerge.exe)
SubtitleEdit: 4.0.10 (C:\Program Files\Subtitle Edit\SubtitleEdit.exe)
================================================================================
```

For passthrough jobs (software, ebooks, etc.), the Quality and Group fields are omitted since no media metadata is parsed.
