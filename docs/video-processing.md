# Video Processing

The Video phase handles three tasks in order: extracting RAR archives, remuxing MP4/M4V files to MKV, and stripping unwanted subtitle tracks from MKV containers. Each step runs only when the input requires it. This phase runs only for TV and movie labels; downloads with unknown labels go through [passthrough mode](labels.md) and skip video processing entirely.

---

## RAR Extraction

When a download is packed in a RAR archive, Stagearr extracts it before any other processing. Both single-part (`.rar`) and multi-part (`.r00`, `.r01`, ...) archives are supported.

**Tool required:** WinRAR (`tools.winrar` in config)

Stagearr uses WinRAR to extract directly into the staging folder. Archive safety checks run before extraction:

- Path traversal entries (`..\\`, absolute paths) cause the archive to be rejected entirely
- Archives that pass the scan are extracted; the original RAR files are not copied to staging

After extraction, Stagearr scans the staging folder for video files and processes each one as described in the sections below.

---

## MP4 / M4V to MKV Remux

MP4 and M4V containers are remuxed into MKV. The remux copies all streams without re-encoding, so there is no quality loss and the process is fast.

**Why MKV?** MKV is a more flexible container for subtitle tracks, chapter markers, and multiple audio streams. Downstream steps (subtitle stripping and extraction) require MKV.

**Tool required:** mkvmerge (`tools.mkvmerge` in config)

**Config:**

```toml
[video.mp4Remux]
enabled = true
```

Disable this feature if all your downloads are already in MKV format. When disabled and a download contains MP4 files, those files are still copied to staging but are not converted.

The remux command strips global tags and track tags for a clean output file. Exit code 1 from mkvmerge (warnings) is treated as success; exit code 2 or higher is treated as failure.

---

## Subtitle Track Stripping

After remux, Stagearr analyzes each MKV file for subtitle tracks. Tracks not in your `subtitles.wantedLanguages` list are candidates for removal. Tracks whose names match `subtitles.namePatternsToRemove` (for example, "Forced" or "Signs") are removed, but only if a clean alternative exists in the same language.

**Tool required:** mkvmerge (`tools.mkvmerge` in config)

**Config:**

```toml
[subtitles.stripping]
enabled = true
```

Image-based subtitle formats (PGS, VobSub) are preserved in the MKV even after stripping because they cannot be converted to SRT. Only unwanted text-format tracks are removed.

**Protection rule:** If none of your wanted languages are found in the MKV, no tracks are stripped. This prevents accidentally removing all subtitles when language tags are missing or unexpected.

Stripping produces a new MKV with only the desired tracks. The original staged file is replaced by the remuxed output.

---

## Handoff to Subtitles Phase

After stripping, the resulting MKV files are handed to the [Subtitle Processing](subtitles.md) phase. Subtitle extraction (MKV track to SRT) happens there, not here.

---

## Prerequisites

| Tool | Used for | Config key |
|------|----------|------------|
| WinRAR | RAR extraction | `tools.winrar` |
| mkvmerge (MKVToolNix) | MP4 remux, subtitle stripping | `tools.mkvmerge` |
| mkvextract (MKVToolNix) | Subtitle extraction (next phase) | `tools.mkvextract` |

Tools only need to be installed for the features you enable. See [Installation](installation.md) for download links and path configuration.
