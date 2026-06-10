# Quick Start

This page walks through the first things to do after installing Stagearr: running the setup wizard, processing a download manually, and checking the queue.

Before starting, make sure you have completed [Installation](installation.md) and (if you want automatic processing) [qBittorrent Integration](qbittorrent.md).

---

## Step 1: Run the interactive setup wizard

The setup wizard creates your `config.toml` interactively. It prompts for the most important settings and writes a valid config file without requiring you to edit TOML by hand.

Open a PowerShell prompt in the Stagearr installation folder and run:

```powershell
.\Stagearr.ps1 -Setup
```

The wizard walks through:

- File system paths (staging folder, log archive, queue folder)
- Which importers to enable (Radarr, Sonarr, Medusa)
- API host, port, and key for each enabled importer
- Email notification settings

You can re-run `-Setup` at any time to update settings. It reads your existing `config.toml` and pre-fills current values.

After the wizard finishes, open `config.toml` in a text editor to review the result. The [Configuration Overview](configuration.md) and [Settings Reference](settings-reference.md) describe every available setting.

---

## Step 2: Process a download manually

Before relying on the qBittorrent hook, verify that processing works end-to-end by running Stagearr manually on a real download.

```powershell
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie"
```

Replace the path and label with a real download. Stagearr will:

1. Copy or extract files to the staging folder.
2. Remux MP4 to MKV (if enabled).
3. Process subtitles (extract, download, clean).
4. Import to Radarr, Sonarr, or Medusa based on the label.
5. Send an email notification (if configured).

By default, the script enqueues the job, acquires the lock, and processes immediately. You see console output as each phase completes.

If you want to run a test without sending an email:

```powershell
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -SkipEmail
```

If you want to keep the staging folder after processing (useful for inspecting intermediate files):

```powershell
.\Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -NoCleanup
```

---

## Step 3: Check queue status

At any time you can inspect what Stagearr is doing:

```powershell
.\Stagearr.ps1 -Status
```

This prints:

- Counts of pending, running, completed, and failed jobs.
- The current lock holder and its last heartbeat time.
- Details of recent jobs, including outcome and timestamps.

Use `-Status` to confirm a manual run succeeded, to check whether the qBittorrent hook is queuing jobs correctly, or to investigate a stuck or failed job.

---

## Step 4: Sync config after updates

When you update Stagearr, new settings may appear in `config-sample.toml` that are not yet in your `config.toml`. Run:

```powershell
.\Stagearr.ps1 -SyncConfig
```

This compares your `config.toml` against `config-sample.toml` and reports:

- Settings present in the sample but missing from your config (new features you may want to enable).
- Settings in your config that no longer exist in the sample (keys you can remove).

You only need to add settings you want to change from their defaults. Stagearr applies built-in defaults for anything not present in `config.toml`.

---

## Next steps

- **[Configuration Overview](configuration.md):** Understand the config file structure and all available sections.
- **[Settings Reference](settings-reference.md):** Full list of every setting with its type, default, and description.
- **[CLI Usage and Parameters](cli-usage.md):** All command-line parameters, modifiers, and examples.
