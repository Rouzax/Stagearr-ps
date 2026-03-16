# Subtitle Processing

Stagearr provides comprehensive subtitle handling with multiple acquisition sources and cleanup stages.

---

## Subtitle Extraction

Extracts text subtitle tracks from MKV files to standalone SRT files.

**Extractable formats:** S_TEXT/UTF8 (SRT), SubRip, WebVTT, ASS/SSA
**Preserved in MKV:** PGS and VobSub tracks are image-based and cannot be converted to SRT — they stay in the MKV file.

### Language Detection

Uses proper ISO 639-1/639-2 language code handling to identify tracks. Only tracks matching your `subtitles.wantedLanguages` are extracted.

### Duplicate Language Handling

When multiple tracks exist for the same language:

| Mode | Behavior | Output |
|------|----------|--------|
| `all` | Keep all tracks with numeric suffixes | `.en.srt`, `.en.1.srt`, `.en.2.srt` |
| `largest` | Keep only the biggest track per language | `.en.srt` |

Configure with `subtitles.extraction.duplicateLanguageMode`.

### Protection Rule

If **none** of your wanted languages are found in the MKV, ALL subtitle tracks are preserved (not stripped). This prevents accidentally removing all subtitles when language tags are missing or unexpected.

---

## Subtitle Stripping

Removes unwanted subtitle tracks from the MKV container itself (not just extraction — actually removes them from the file).

### How It Works

1. Analyzes all subtitle tracks in the MKV
2. Keeps tracks matching your `subtitles.wantedLanguages`
3. Removes tracks matching `subtitles.namePatternsToRemove` patterns — but **only if** a clean alternative exists in the same language
4. Remuxes the MKV without the unwanted tracks

### Pattern Matching

The `namePatternsToRemove` setting matches against subtitle track names:

```toml
namePatternsToRemove = ["Forced", "Signs", "Songs"]
```

A track named "English (Forced)" would be removed only if another English track exists without those patterns. This ensures you always have at least one subtitle track per wanted language.

---

## OpenSubtitles Integration

Downloads subtitles from OpenSubtitles.com using the REST API v1.

### Authentication

Requires an OpenSubtitles.com account and API key. Token caching provides persistent authentication across sessions — you don't need to re-authenticate each run.

### Matching

Uses **video hash matching** for accurate subtitle pairing. The file hash identifies the exact release, providing better matches than filename-based searching.

### Filters

Control which subtitles are downloaded:

| Filter | Options | Default | Description |
|--------|---------|---------|-------------|
| `hearingImpaired` | `include`, `exclude`, `only` | `exclude` | Subtitles with [HI] tags |
| `foreignPartsOnly` | `include`, `exclude`, `only` | `exclude` | Foreign language parts only |
| `machineTranslated` | `include`, `exclude`, `only` | `exclude` | Machine-translated subtitles |
| `aiTranslated` | `include`, `exclude`, `only` | `include` | AI-translated subtitles |

### Configuration

```toml
[subtitles.openSubtitles]
enabled = true
user = "your_username"
password = "your_password"
apiKey = "your_api_key"

[subtitles.openSubtitles.filters]
hearingImpaired = "exclude"
foreignPartsOnly = "exclude"
machineTranslated = "exclude"
aiTranslated = "include"
```

---

## Subtitle Upload

Uploads cleaned extracted subtitles back to OpenSubtitles, contributing to the community database.

### What Gets Uploaded

Only subtitles **extracted from MKV files** are uploaded. Downloaded subtitles (from OpenSubtitles itself) are excluded to avoid re-uploading existing content. Subtitles are cleaned with SubtitleEdit before upload.

### Guards

Several checks prevent bad uploads:
- **Filename validation** rejects generic names (`_unpack`, `video`, `output`) and filenames without proper metadata (season/episode for TV, multi-word titles for movies)
- **Duplicate detection** checks if a subtitle already exists on OpenSubtitles for the same video hash and language before uploading
- **Rate limiting** adds a 250ms delay between API calls to respect the 40 requests/10 seconds limit

### Upload Exclude List

Some shows have notoriously bad embedded subtitles. Use `uploadExclude` to prevent uploading for specific shows:

```toml
[subtitles.openSubtitles]
uploadExclude = ["tt2140481", "Last Week Tonight with John Oliver"]
```

Entries starting with `tt` followed by digits are matched against the IMDB ID. All other entries are matched case-insensitively against the show/movie title from OMDb.

### Diagnostic Mode

Enable `uploadDiagnosticMode` to see what would be uploaded without actually uploading. This logs each subtitle's eligibility status so you can verify the guards work correctly before going live.

```toml
[subtitles.openSubtitles]
uploadCleaned = true
uploadDiagnosticMode = true
```

---

## SubtitleEdit Cleanup

Cleans downloaded and extracted SRT files using SubtitleEdit's command-line interface.

### What It Does

- **Hearing Impaired Removal** — Strips `[brackets]` and `(parentheses)` tags (e.g., `[door closes]`, `(sighs)`)
- **Error Correction** — Fixes common OCR and timing issues
- **Batch Processing** — Cleans all subtitles in a single pass

### Configuration

```toml
[subtitles.cleanup]
enabled = true
```

Requires SubtitleEdit installed and configured in `[tools]`:

```toml
[tools]
subtitleEdit = "C:/Program Files/Subtitle Edit/SubtitleEdit.exe"
```

---

## Processing Order

Subtitles are processed in this order during the pipeline:

1. **Strip** unwanted tracks from MKV (if enabled)
2. **Extract** remaining text tracks to SRT files (if enabled)
3. **Download** missing subtitles from OpenSubtitles (if enabled)
4. **Clean** all SRT files with SubtitleEdit (if enabled)
5. **Upload** cleaned extracted subtitles to OpenSubtitles (if enabled)

Each step is independently togglable via feature flags.
