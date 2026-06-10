# Configuration Overview

Stagearr uses a [TOML](https://toml.io/) configuration file (`config.toml`) in the repository root. TOML is a simple key-value format that supports `#` comments on any line, making it easy to annotate your settings.

## Setting up config.toml

Stagearr ships with a fully commented sample file called `config-sample.toml`. To configure Stagearr, copy it and edit the copy:

```
copy config-sample.toml config.toml
```

You do **not** need to include every setting. Any key you leave out is automatically filled in from the built-in defaults. Only include the settings you want to change.

### Path format in TOML

TOML treats the backslash (`\`) as an escape character. Use forward slashes or double backslashes in all path values:

```toml
# Both of these work:
stagingRoot = "C:/Staging"
stagingRoot = "C:\\Staging"

# This does NOT work:
stagingRoot = "C:\Staging"
```

## First-time setup wizard

If you prefer a guided setup, run:

```powershell
.\Stagearr.ps1 -Setup
```

The wizard walks you through the required settings interactively and writes `config.toml` for you. You can run it again at any time to reconfigure.

## Keeping config in sync after updates

When Stagearr adds new settings, your existing `config.toml` will not have them (they fall back to built-in defaults, so nothing breaks). To see which settings are missing from your file or which keys no longer exist, run:

```powershell
.\Stagearr.ps1 -SyncConfig
```

This reports missing keys (settings added since you last updated your config) and extra keys (settings you have that Stagearr no longer recognizes). It does not modify your file; it just reports what changed so you can add or remove entries manually.

## What needs to be configured

A minimal working config needs:

- `paths.stagingRoot`, `paths.logArchive`, `paths.queueRoot` (required paths with no default)
- `tools.winrar` (RAR extraction is always active)
- `tools.mkvmerge` and/or `tools.mkvextract` if the video/subtitle features that need them are enabled
- API keys and hosts for whichever importers (Radarr, Sonarr, Medusa) you use

Everything else has a working default. See [Settings Reference](settings-reference.md) for the full list, and [Labels & Content Routing](labels.md) for how torrent labels map to content types and importers.
