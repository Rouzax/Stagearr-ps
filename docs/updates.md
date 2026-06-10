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

# Hours between automatic update checks (0 = check on every run)
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

## Update Mechanism

Stagearr uses two distinct update paths depending on how it was installed.

### Standard installation (ZIP download)

For installations set up by downloading a release ZIP (the recommended installation method), the
updater:

1. Queries the GitHub Releases API for the latest release.
2. Downloads the release ZIP asset and its SHA256 checksum file.
3. Verifies the SHA256 checksum before extracting.
4. Extracts the ZIP to a temporary directory.
5. Copies everything from the extracted ZIP over the script root in place. The release ZIP
   contains only the runtime files (`Stagearr.ps1`, `Modules/`, `config-sample.toml`, `LICENSE`,
   `README.md`), so the overwrite is limited to those. Your `config.toml`, queue data, and log
   files live outside the ZIP and are not affected.
6. Cleans up the temporary directory.

This is the primary update path. If the download or checksum verification fails, Stagearr falls
back to printing the release URL so you can update manually.

### Git-clone installation

If Stagearr's script root contains a `.git` directory, the updater treats the installation as a
git clone and uses `git` commands instead of the ZIP download:

1. Runs `git fetch --tags` to retrieve the latest tags from the remote.
2. Stashes any uncommitted local changes if present.
3. Attempts `git checkout <tag>` for the new release tag.
4. If tag checkout fails, falls back to `git pull` on the current branch.

!!! note
    You do not need to run `git pull` manually. The `-Update` flag and automatic background
    checks handle this for you. Running `git pull` directly is only appropriate if you are
    actively developing Stagearr, not for production use.

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
