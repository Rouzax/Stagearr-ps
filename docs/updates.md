# Auto-Update

Stagearr can check for new releases on GitHub and apply updates automatically. The behavior is
controlled by the `[updates]` section in `config.toml`.

## Configuration

```toml
[updates]
# "auto"   = download and apply updates from GitHub Releases automatically
# "notify" = report available updates in email/console, do not apply
# "off"    = disable all update checking
mode = "auto"

# Hours between automatic update checks
checkIntervalHours = 24
```

| Key | Default | Description |
|-----|---------|-------------|
| `mode` | `"auto"` | Update behavior: `auto`, `notify`, or `off`. |
| `checkIntervalHours` | `24` | Minimum hours between checks. Set to `0` to check every run. The last-check timestamp is stored in `queueRoot`. |

## Running an Immediate Update Check

Use `-Update` to bypass the interval timer and check for updates right now:

```powershell
.\Stagearr.ps1 -Update
```

This always contacts GitHub regardless of when the last check ran. If an update is found, the
behavior depends on `updates.mode`:

- **`auto`:** Applies the update immediately (no prompt).
- **`notify` or `off`:** Prompts you to confirm before applying.

After a successful update, run `-SyncConfig` to pick up any new configuration keys:

```powershell
.\Stagearr.ps1 -SyncConfig
```

## Automatic Background Checks

When `mode` is `auto` or `notify`, Stagearr checks for updates at the start of each normal
processing run if `checkIntervalHours` has elapsed since the last check. This runs silently in
the background and does not delay job processing.

- In `notify` mode, an available update is reported in the console output and in the email
  notification for that run, with a link to the release page.
- In `auto` mode, the update is downloaded and applied before the job starts.

!!! note "Updates never run while another job is processing"
    Stagearr applies an update only when no other worker is busy. If a second run starts
    while one is mid-job (for example, two torrents finishing close together), the update is
    deferred rather than applied on top of the running worker, and it is applied on a later
    check instead. The `-Update` command behaves the same way: if a worker is currently
    processing, it reports that the update was deferred and asks you to re-run when idle
    (check with `.\Stagearr.ps1 -Status`).

## Update Mechanism

Stagearr uses two distinct update paths depending on how it was installed.

### Standard installation (ZIP download)

For installations set up by downloading a release ZIP (the recommended installation method), the
updater:

1. Queries the GitHub Releases API for the latest release.
2. Downloads the release ZIP asset and its `checksums.txt` file.
3. Verifies the SHA256 checksum of the downloaded ZIP against the matching entry in
   `checksums.txt`. If no entry matches the ZIP filename, or if the hashes differ, the update is
   aborted and nothing is written to disk.
4. Extracts the ZIP to a temporary directory (extraction only happens after verification passes).
5. Applies the update atomically: for each top-level item in the release (`Stagearr.ps1`,
   `Modules/`, `config-sample.toml`, `LICENSE`, `README.md`), the new content is staged into a
   temporary sibling path, the existing item is moved aside to a backup, and then the new content
   is swapped into place. If anything fails partway (disk full, locked file, interrupted run), all
   already-swapped items are restored from their backups, leaving the previous working install
   intact.
6. Removes any file that belonged to the previous release but is absent from the new one (for
   example, a module script that was renamed or deleted). This prevents stale files from being
   loaded alongside the updated code.
7. Cleans up the temporary directory.

!!! note "What stays untouched"
    Pruning is bounded to the files the release owns (listed in step 5). Everything else is
    treated as user data and is never removed: `config.toml`, queue data (`queueRoot/`), log
    archives (`logArchive/`), staging files (`stagingRoot/`), and the `.git` directory are all
    left intact.

If the download, checksum verification, or apply step fails, Stagearr reports the failure and
prints the release URL so you can update manually.

### Git-clone installation

!!! warning
    This path is for development only, not for production use. If you installed Stagearr by
    downloading a release ZIP, you will never hit this path. Do not run `git pull` manually;
    the `-Update` flag and automatic background checks handle updates for you.

If Stagearr's script root contains a `.git` directory, the updater treats the installation as a
git clone and uses `git` commands instead of the ZIP download:

1. Runs `git fetch --tags` to retrieve the latest tags from the remote.
2. Stashes any uncommitted local changes if present.
3. Attempts `git checkout <tag>` for the new release tag.
4. If tag checkout fails, falls back to `git pull` on the current branch.

## After an Update

New releases may add configuration keys. After updating, check whether your config is missing
any new settings:

```powershell
.\Stagearr.ps1 -SyncConfig
```

`-SyncConfig` compares your `config.toml` against `config-sample.toml` and reports any missing
or extra keys.

## Related

- [Installation](installation.md) for how to perform an initial install from a release ZIP.
- [CLI Usage & Parameters](cli-usage.md) for the full `-Update` parameter reference.
