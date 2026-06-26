# Subtitle Processing

Stagearr provides comprehensive subtitle handling with multiple acquisition sources and cleanup stages. Every step in this phase is independently enabled or disabled via feature flags, so you can use as much or as little as your setup requires.

---

## Processing Order

Subtitles are processed in this order:

1. **Extract** text tracks from the MKV container to SRT files (Video phase, if enabled)
2. **Strip** unwanted tracks from the MKV container (Video phase, if enabled)
3. **Download** missing subtitles from OpenSubtitles (if enabled)
4. **Clean** all SRT files with SubtitleEdit (if enabled)
5. **Upload** cleaned extracted subtitles back to OpenSubtitles (if enabled)

Steps 1 and 2 both happen in the [Video phase](video-processing.md); extraction runs first so the extracted SRT files are preserved before any tracks are removed from the MKV. The sections below cover each step in detail.

---

## Subtitle Extraction

Stagearr extracts text subtitle tracks embedded in MKV files to standalone SRT files alongside the video.

**Tool required:** mkvextract (`tools.mkvextract` in config)

**Config:**

```toml
[subtitles.extraction]
enabled = true
duplicateLanguageMode = "all"
```

Disable extraction if you prefer your media player to select subtitle tracks directly from the MKV.

### Extractable formats

| Format | Extracted to SRT |
|--------|-----------------|
| S_TEXT/UTF8 (SRT) | Yes |
| SubRip | Yes |
| WebVTT | Yes |
| ASS / SSA | Yes |
| PGS (image-based) | No (stays in MKV) |
| VobSub (image-based) | No (stays in MKV) |

Image-based formats (PGS, VobSub) cannot be converted to SRT and remain in the MKV container.

### Language detection

Stagearr uses ISO 639-1 and ISO 639-2 language code handling to identify tracks. Only tracks matching your `subtitles.wantedLanguages` are extracted.

```toml
[subtitles]
wantedLanguages = ["eng", "nld"]
```

### Duplicate language handling

When an MKV contains multiple subtitle tracks for the same language, the `duplicateLanguageMode` setting controls which tracks are kept:

| Mode | Behavior | Output filenames |
|------|----------|-----------------|
| `all` | Keep all tracks with numeric suffixes (default) | `movie.en.srt`, `movie.en.1.srt`, `movie.en.2.srt` |
| `largest` | Keep only the biggest track per language | `movie.en.srt` |

### Protection rule

If none of your wanted languages are found in the MKV, all subtitle tracks are preserved rather than stripped. This prevents accidentally removing all subtitles when track language tags are missing or use an unexpected code.

---

## Subtitle Stripping

Stripping removes unwanted subtitle tracks from the MKV container itself. This is distinct from extraction: stripping modifies the MKV file to remove tracks entirely; extraction pulls tracks out to separate SRT files.

**Tool required:** mkvmerge (`tools.mkvmerge` in config)

**Config:**

```toml
[subtitles.stripping]
enabled = true
```

```toml
[subtitles]
wantedLanguages = ["eng", "nld"]
namePatternsToRemove = ["Forced", "Signs", "Songs"]
```

### How stripping works

1. Analyzes all subtitle tracks in the MKV
2. Keeps tracks matching `wantedLanguages`
3. Removes tracks matching `namePatternsToRemove`, but only if a clean alternative exists in the same language
4. Remuxes the MKV without the removed tracks

A track named "English (Forced)" is removed only if another English track without those patterns exists. This ensures you always have at least one subtitle track per wanted language.

The same protection rule described under [Subtitle Extraction](#protection-rule) applies: if none of your wanted languages are found, no tracks are stripped.

---

## OpenSubtitles Integration

Stagearr downloads subtitles from OpenSubtitles.com using the REST API v1 when wanted languages are not already present.

**Config:**

```toml
[subtitles.openSubtitles]
enabled = true
user = "your_username"
password = "your_password"
apiKey = "your_api_key"
```

You need an OpenSubtitles.com account and a free API key. Authentication tokens are cached on disk so you do not need to re-authenticate each run.

### Matching

Stagearr uses video hash matching for accurate subtitle pairing. The file hash identifies the exact release, providing better results than filename-based searching.

### Filters

Control which subtitles are downloaded:

| Filter | Options | Default | Description |
|--------|---------|---------|-------------|
| `hearingImpaired` | `include`, `exclude`, `only` | `exclude` | Subtitles with hearing-impaired annotations |
| `foreignPartsOnly` | `include`, `exclude`, `only` | `exclude` | Subtitles that cover only foreign-language parts |
| `machineTranslated` | `include`, `exclude`, `only` | `exclude` | Machine-translated subtitles |
| `aiTranslated` | `include`, `exclude`, `only` | `include` | AI-translated subtitles |

```toml
[subtitles.openSubtitles.filters]
hearingImpaired = "exclude"
foreignPartsOnly = "exclude"
machineTranslated = "exclude"
aiTranslated = "include"
```

---

## Subtitle Upload

When `uploadCleaned = true`, Stagearr uploads cleaned subtitles back to OpenSubtitles after processing, contributing to the community database.

```toml
[subtitles.openSubtitles]
uploadCleaned = false
uploadDiagnosticMode = false
uploadExclude = []
```

### What gets uploaded

Only subtitles **extracted from MKV files** are uploaded. Subtitles downloaded from OpenSubtitles in the same run are excluded to avoid re-uploading existing content.

### Upload guards

Several checks prevent bad uploads:

- **Filename validation** rejects generic names (`_unpack`, `video`, `output`) and filenames without proper metadata (season/episode for TV, multi-word title for movies)
- **Duplicate detection** checks if the subtitle already exists on OpenSubtitles for the same video hash and language before uploading
- **Rate limiting** adds a 250 ms delay between API calls to stay within the 40 requests per 10 seconds limit

### Upload exclude list

Some shows have notoriously bad embedded subtitles. Use `uploadExclude` to prevent uploading for specific titles:

```toml
[subtitles.openSubtitles]
uploadExclude = ["tt2140481", "Last Week Tonight with John Oliver"]
```

Entries starting with `tt` followed by digits are matched against the IMDB ID. All other entries are matched case-insensitively against the show or movie title from OMDb, Sonarr, or Radarr.

### Diagnostic mode

Enable `uploadDiagnosticMode` to log what would be uploaded without actually uploading. Use this to verify the guards work correctly before going live:

```toml
[subtitles.openSubtitles]
uploadCleaned = true
uploadDiagnosticMode = true
```

---

## Subtitle Cleanup

All SRT files (both extracted and downloaded) are cleaned using the cleanup engine selected by your `tools.subtitleEdit` path. Cleanup runs on every SRT file present after extraction and download, regardless of its source.

**Tool required:** Subtitle Edit or seconv (`tools.subtitleEdit` in config)

**Config:**

```toml
[subtitles.cleanup]
enabled = true

removeHearingImpaired = true
mergeSameTexts        = true
fixCommonErrors       = true
splitLongLines        = false
```

### Two cleanup engines

Stagearr supports two cleanup engines. The engine that runs is determined by your `tools.subtitleEdit` path.

**seconv** (recommended): A standalone command-line tool shipped with Subtitle Edit v5 (available from v5.1.0-beta1 onward as the `SeConv-<os>` release asset on GitHub). Point `tools.subtitleEdit` at the **install folder** and seconv is used automatically when present. On Linux, the native libraries required by seconv are bundled in the `SeConv-linux` release asset, so no separate library installation is needed.

**SubtitleEdit.exe** (GUI): The classic Windows GUI application, which also accepts command-line arguments. When `tools.subtitleEdit` points at a folder that contains only `SubtitleEdit.exe` (no seconv binary), the GUI binary is used instead.

To select the engine, set `tools.subtitleEdit` to the **install folder** (recommended) rather than a specific binary. Stagearr checks the folder and prefers seconv over SubtitleEdit.exe when both are present. You can also point directly at a binary to pin the engine explicitly.

### What cleanup does

The four operations below are toggled by individual config keys. Both engines support all four; the keys apply to whichever engine is active.

| Config key | Default | What it removes or changes |
|-----------|---------|---------------------------|
| `removeHearingImpaired` | `true` | `[brackets]` and `(parentheses)` annotations such as `[door closes]` or `(sighs)` |
| `mergeSameTexts` | `true` | Consecutive identical lines merged into one cue |
| `fixCommonErrors` | `true` | Encoding artifacts, casing, punctuation, and timing/formatting mistakes |
| `splitLongLines` | `false` | Lines exceeding the display width split across two lines |

These keys control **which operations run**. How each operation behaves internally is controlled separately (see seconv-only settings below).

### seconv-only settings

Two additional keys are only meaningful when seconv is the active engine. They have no effect when SubtitleEdit.exe is used.

**`fixCommonErrorsRules`** controls which FixCommonErrors rules seconv applies. The default excludes two rules that change output in ways the SubtitleEdit.exe batch mode does not:

- `FixShortGaps` shifts subtitle timecodes, which can desync dialogue from audio.
- `FixShortLinesPixelWidth` re-flows line breaks based on pixel width, which produces different line breaks than the GUI's character-count mode.

The default `"all,-FixShortGaps,-FixShortLinesPixelWidth"` means: apply all rules except those two. Override this only if you understand what each excluded rule does.

**`seconvSettings`** points to a custom seconv settings JSON file that controls **how** operations behave (font, margins, display settings, per-rule parameters). Leave it empty to use the bundled SE4 default profile. Provide a path only if you have exported a custom profile from the Subtitle Edit GUI and want seconv to use the same settings.

```toml
[subtitles.cleanup]
fixCommonErrorsRules = "all,-FixShortGaps,-FixShortLinesPixelWidth"
seconvSettings = ""
```

### Limitations

**Music symbol normalization** (`MusicSymbolReplace`): The Subtitle Edit GUI reads its own `Settings.xml` to determine which music symbol characters to normalize. seconv uses the bundled profile instead. If you rely on a custom music symbol replacement configured in the GUI, that customization is not reproducible in seconv unless you provide the same settings via `seconvSettings`.

**No dictionary-based OCR or spelling repair (seconv):** The Subtitle Edit GUI's `fixCommonErrors` includes a dictionary-backed OCR-error and spell-check pass (the `FixCommonOcrErrors` rule) that corrects misrecognized characters and misspellings using its installed dictionaries. seconv omits that rule because it needs the GUI's spell-check engine, so seconv applies structural, formatting, casing, punctuation, and timing fixes only, not dictionary-based corrections. If you depend on OCR/spell repair, keep using the SubtitleEdit.exe engine.

---

## Summary of Feature Flags

| Config key | Default | Controls |
|-----------|---------|---------|
| `subtitles.extraction.enabled` | `true` | Extract MKV text tracks to SRT |
| `subtitles.stripping.enabled` | `true` | Remove unwanted MKV tracks |
| `subtitles.cleanup.enabled` | `true` | Clean SRT files with the subtitle cleanup engine |
| `subtitles.openSubtitles.enabled` | `false` | Download from OpenSubtitles |
| `subtitles.openSubtitles.uploadCleaned` | `false` | Upload cleaned subtitles |

For all subtitle settings and their defaults, see the [Settings Reference](settings-reference.md).
