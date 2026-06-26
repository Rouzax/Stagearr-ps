# Changelog

All notable changes to this project are documented here. This file starts at v2.10.0; for earlier history see the [GitHub Releases](https://github.com/Rouzax/Stagearr-ps/releases).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Removed dead PowerShell 5.1 compatibility code now that PowerShell 7.0 is required: TLS 1.2 forcing in HTTP/OMDb/email/update paths, and the `$IsWindows` and `Invoke-WebRequest -UseBasicParsing` polyfills. No behavior change on PowerShell 7.

## [2.10.0] - 2026-06-26

### Added
- **seconv subtitle-cleanup engine.** Auto-detected from the `tools.subtitleEdit` path (install folder or binary; seconv is preferred over the SubtitleEdit GUI when both are present), enabling cross-platform cleanup. Ships a bundled SE4-profile settings JSON (override via `subtitles.cleanup.seconvSettings`), validated to roughly 99.7% output parity with SubtitleEdit 4.0.16.
- New `[subtitles.cleanup]` options: `removeHearingImpaired`, `mergeSameTexts`, `fixCommonErrors`, `splitLongLines`, plus the seconv-only `fixCommonErrorsRules` and `seconvSettings`. The seconv engine requires SubtitleEdit/seconv v5.1.0-beta1 or newer.

### Changed
- **Breaking:** Stagearr now requires PowerShell 7.0. Windows PowerShell 5.1 is no longer supported.

### Notes
- Existing configs that point `tools.subtitleEdit` at `SubtitleEdit.exe` continue to use the GUI engine unchanged.
- seconv does not perform dictionary or OCR-error repair (the GUI's `FixCommonOcrErrors` rule is excluded from the CLI); it applies structural, formatting, casing, punctuation, and timing fixes.
