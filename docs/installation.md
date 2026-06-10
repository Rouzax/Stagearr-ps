# Installation

## Prerequisites

### PowerShell

Stagearr requires **PowerShell 5.1** (included with Windows 10 and later) or **PowerShell 7.x**. No extra installation is needed on a modern Windows machine.

### Windows

Stagearr runs on Windows only. The pipeline depends on Windows paths and integrates with qBittorrent running on Windows.

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

Clone the repository to a stable path on your Windows machine. Stagearr reads its own location at startup, so do not move the folder after configuring qBittorrent.

```powershell
git clone https://github.com/Rouzax/Stagearr-ps.git C:\Stagearr-ps
```

If you prefer not to use git, download the latest release zip from the [Releases page](https://github.com/Rouzax/Stagearr-ps/releases) and extract it to your chosen path.

---

## Configure tool paths

After installing the external tools, tell Stagearr where to find them. Tool paths are set in the `[tools]` section of `config.toml`.

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
- **[Quick Start](quick-start.md):** Run the interactive setup wizard and process your first download.
