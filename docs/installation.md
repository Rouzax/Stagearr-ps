# Installation

## Prerequisites

Stagearr runs on Windows only. The pipeline depends on Windows paths and integrates with qBittorrent running on Windows.

### PowerShell

Stagearr runs on **PowerShell 7.x** (recommended) or **Windows PowerShell 5.1** (included with Windows 10 and later). PowerShell 7 is a free, separate install from Microsoft ([get it here](https://aka.ms/powershell)) and is the preferred runtime. Windows PowerShell 5.1 works too and needs no extra installation.

### External tools

Stagearr calls external tools for specific processing stages. Each tool is only required if the corresponding feature is enabled in your configuration. If you disable a feature, you do not need to install its tool.

| Tool | Download | Required for |
|------|----------|--------------|
| [WinRAR](https://www.win-rar.com/) | win-rar.com | RAR archive extraction |
| [MKVToolNix](https://mkvtoolnix.download/) | mkvtoolnix.download | MP4-to-MKV remux, subtitle track extraction and stripping |
| [SubtitleEdit](https://github.com/SubtitleEdit/subtitleedit) | GitHub releases | Subtitle cleanup (HI tag removal, error correction) |

MKVToolNix provides two executables that Stagearr uses separately: `mkvmerge` (for remux and track stripping) and `mkvextract` (for subtitle extraction). Both are installed in the same MKVToolNix directory.

### Optional PowerShell module

[Mailozaurr](https://github.com/EvotecIT/Mailozaurr) v2.x enables inline poster images and implicit SSL in email notifications. Without it, Stagearr falls back to PowerShell's built-in `Send-MailMessage`, which works for basic email but does not support inline images.

```powershell
Install-Module Mailozaurr -AllowPrerelease
```

---

## Download Stagearr

Download the latest release zip from the [Releases page](https://github.com/Rouzax/Stagearr-ps/releases) and extract it to a stable path on your Windows machine (for example `C:\Stagearr-ps`). This is the recommended method: a release-zip install updates itself cleanly in place (see [Auto-Update](updates.md)).

Stagearr reads its own location at startup, so do not move the folder after you configure qBittorrent.

If you plan to develop or contribute to Stagearr, you can instead clone the repository with git:

```powershell
git clone https://github.com/Rouzax/Stagearr-ps.git C:\Stagearr-ps
```

A git clone updates with `git pull` rather than from the release zip, and that path is intended for development. See [Auto-Update](updates.md) for the difference between the two.

---

## Create your configuration

Run the interactive setup wizard to generate your `config.toml`:

```powershell
.\Stagearr.ps1 -Setup
```

The wizard walks through your working paths, external tool locations, importer (Radarr, Sonarr, or Medusa) connection details, and email notifications, then writes `config.toml`. You can re-run it at any time to change settings, or edit `config.toml` by hand afterward. If you would rather start from a template, copy `config-sample.toml` to `config.toml` and edit it directly.

Only the settings you change from the defaults need to be present in `config.toml`; everything else falls back to built-in defaults. See the [Settings Reference](settings-reference.md) for every available key.

---

## Configure tool paths

After installing the external tools, tell Stagearr where to find them. Tool paths are set in the `[tools]` section of `config.toml`. If you ran `-Setup` above, the wizard already created `config.toml` and recorded these paths; you can adjust them there or edit the file directly.

The [Settings Reference](settings-reference.md) documents each path key, including the `[tools]` section. Default values in `config-sample.toml` point to standard installation locations:

```toml
[tools]
# Paths to external tools - only needed for enabled features
winrar    = "C:/Program Files/WinRAR/RAR.exe"
mkvmerge  = "C:/Program Files/MKVToolNix/mkvmerge.exe"
mkvextract = "C:/Program Files/MKVToolNix/mkvextract.exe"
subtitleEdit = "C:/Program Files/Subtitle Edit/SubtitleEdit.exe"
```

If your tools are installed in the default locations, these values will work without changes. Use forward slashes or double backslashes in paths (TOML treats a single backslash as an escape character).

---

## Next steps

- **[qBittorrent Integration](qbittorrent.md):** Set up the completion hook so Stagearr runs automatically when a torrent finishes.
- **[Quick Start](quick-start.md):** Process your first download and confirm the pipeline runs end to end.
