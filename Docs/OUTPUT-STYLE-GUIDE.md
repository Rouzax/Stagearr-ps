# Stagearr Output Style Guide

> **Design philosophy**: Users just want their media in their library with subtitles. Everything we output should serve that goal or get out of the way.
> **Examples**: Examples in this guide illustrate intent and hierarchy; they are **not** verbatim templates. Follow the principles, not the exact wording.


---

## Understanding Our Users

Stagearr serves **two different audiences**, and each output channel is tuned for the people who actually read it.

### Console output is for operators (tech-savvy)

Console output (including **non-verbose**) is written for people who are comfortable with CLI tooling and troubleshooting.

**Assume the console reader**:
- Is technical and wants useful detail (paths, counts, timings, service names)
- Will rerun with different flags or inspect logs to fix issues
- Values consistency over "friendly" phrasing

**Console goals**:
- Make progress and phases obvious at a glance
- Provide enough technical context to troubleshoot without guessing
- Point clearly to the next artifact (log file, email) when something goes wrong

### Email is for operators (tech-savvy, asynchronous)

Email is the **post-run dashboard** for the *same* audience that can read the console output. It's consumed asynchronously (often on a phone), so it should be compact and verdict-first — but it can absolutely use your domain terms (Radarr, Medusa, OpenSubtitles, etc.).

**Assume the email reader**:
- Knows your pipeline and ecosystem (Radarr/Medusa/OpenSubtitles, staging/import, etc.)
- Wants a one-screen summary to triage quickly (especially when multiple jobs run)
- Cares about outcomes: what came in, did it import, do we have the subtitles, were there skips/warnings
- Will open the filesystem log only when something looks off

**Email goals**:
- Answer "Did it work?" immediately (success / warning / failed)
- Identify what was processed (title + label + path context if helpful)
- Summarize the critical outcomes:
  - Video files processed (count)
  - Subtitles status (wanted vs present/downloaded; missing languages)
  - Import target + result (Radarr/Medusa/Sonarr/etc.; imported vs skipped vs failed)
  - Cleanup status and total runtime
- Surface exceptions and anomalies only (missing subs, "file exists", quota issues, retries, archive warnings)
- Include the **plain-text filesystem log path** for full detail (no step-by-step narration in email)


### Filesystem logs are for forensics (deep technical detail)

Logs written to disk exist so an operator can diagnose later, share a report, or audit a run.

**Assume the log reader**:
- Wants the full story (inputs, decisions, timings, service responses)
- Might search, copy/paste, or attach the log to a message
- Needs enough context to debug without rerunning

### What email recipients actually care about

| Priority | Question | When it matters |
|----------|----------|-----------------|
| 1 | Did it work? | Always |
| 2 | What was it? | Always (remind them what this notification is about) |
| 3 | Are subtitles available? | When subtitles are configured |
| 4 | What went wrong? | Only on failure |
| 5 | What should I do? | Only when action is needed |

**Everything else is noise in email.**

---

## Core Principles

### 1. Lead With the Outcome

The most important information comes first. Don't make users wade through process details to find out if it worked.

On the console, this coexists with **short "starting…" lines** for long-running steps (e.g., remuxing) so operators don't mistake normal work for a hang. Those lines should be minimal and must be followed by a clear outcome.

```
# Bad - long narration with no clear outcomes
Processing MKV...
Selecting tracks...
Remuxing...
Cleaning subtitles...
Importing...
Done!

# Good - outcomes are easy to spot, and long steps announce themselves
[17:00:01]     Remuxing: Removing 35 unwanted subtitle tracks...
[17:01:48] ✓ Removed: 35 unwanted subtitles
[17:01:48]   Sending to Radarr...
[17:01:55] ✓ Radarr: Imported (6s)
[17:01:55] ✓ Job: Completed successfully
```

### 2. One Glance Should Be Enough

Users should understand the result within 1-2 seconds of looking. Use visual hierarchy, not walls of text.

**Email**: The subject line and one colored status row tell the whole story.

**Console**: The final success/failure marker is visible without scrolling.

### 3. Explain Failures, Not Successes

Success needs no explanation—it's the expected outcome. Failure needs context: what happened, why, and what to do.

```
# Success - minimal
✓ Inception (2010) added to library

# Failure - detailed
✗ Could not add Inception (2010)
  Problem: Radarr couldn't find the folder
  Location: \\server\movies\Inception (2010)
  
  This usually means the network drive isn't mounted
  or Radarr doesn't have permission to access it.
```

### 4. Use Human Language

Write like you're telling a friend what happened, not writing a log file.

| Instead of | Write |
|------------|-------|
| `Process exited with code 0` | `Complete` |
| `ENOENT: no such file or directory` | `File not found` |
| `HTTP 401 Unauthorized` | `Radarr rejected the request - check your API key` |
| `Timeout after 30000ms` | `Radarr took too long to respond` |
| `Staging path initialized` | *(don't say anything - user doesn't care)* |

### 5. Silence Is Golden

Every line of output is a small tax on the user's attention. Earn it.

**Ask before adding output**:
- Will the user's behavior change based on this information?
- Would they notice or care if this line was missing?
- Does this help them or just make us feel thorough?

When in doubt, leave it out—or make it verbose-only.


### 6. Always Conclude With a Clear Outcome

No run should "just stop." Every job must end with **one** unambiguous terminal line:

- ✓ **Job: Completed successfully**
- ! **Job: Completed with warnings**
- ✗ **Job: Failed: {plain reason}**
- ↷ **Job: Skipped: {plain reason}**

If execution aborts unexpectedly (exception, early exit, lock contention), still emit a terminal line that tells the user what happened and where to look next (log file / email).


---

## Output Contract

To keep console, filesystem logs, and email consistent as the script grows, we treat output as **events** that are later **rendered** for each channel.

Every output event should map cleanly to these fields:

| Field | Meaning | Notes |
|------|---------|------|
| Timestamp | When it happened | Optional in email; useful in console + logs |
| Level | Info / Success / Warning / Error / Verbose | Markers apply only to outcomes |
| Phase | High-level stage (Staging / Subtitles / Import / Cleanup) | Drives section headers |
| Label | Short component tag (Radarr / Medusa / OpenSubs) | Consistent naming matters |
| Indent | Hierarchy level (0-2) | Controls visual nesting in console |
| Text | Human sentence | Plain language; avoid low-level internals (hashes, raw IDs/URLs) |
| Details | Extra key/value context | Shown only in verbose/logs |
| Duration | How long it took | Include on long operations and final outcomes |

**Rule**: Business logic should emit events; renderers decide *how they appear* in console vs email vs HTML. This prevents drift where one channel improves and the others don't.

---

## Console Output

The console is for real-time monitoring. Users watching the console are actively engaged and **want to see what's happening**. Give them the details—they're choosing to watch.

### Philosophy: Show the Work

Unlike email (which should be minimal), console output can and should show the process in detail. Users watching the console want to:
- See that progress is being made
- Understand what the system is doing
- Catch issues as they happen
- Feel confident the system is working correctly

**Don't be shy about detail in the console.** A user staring at a terminal wants information, not mystery.

### Output Modes

Output must remain readable across different terminals and attention levels. Treat these as first-class behaviors:

- **Default**: human progress + outcomes (no internals)
- **`-Verbose`**: adds troubleshooting detail (the "layer beneath"), without repeating standard lines
- **`-Quiet`** (recommended): only outcomes + actionable warnings/errors (no progress narration)
- **`-NoColor`**: never rely on color; markers + text must carry meaning
- **`-Ascii`**: replace Unicode markers/lines with ASCII equivalents for legacy consoles

If a feature can't meet these modes cleanly, it's a sign the output is too tightly coupled to a specific renderer.

### Visual Structure

```
[17:00:01] ✓ Label: Message
└────────┘ │ └───┘  └─────┘
    │      │   │       └── What happened (human readable)
    │      │   └────────── What component (short, consistent)
    │      └────────────── Outcome indicator
    └────────────────────── When (for correlation)
```

### Indentation Hierarchy

The console uses a 4-tier indentation scheme for clear visual hierarchy. This scheme applies **identically** to single-file and batch modes:

| Level | Spaces | Usage | Example |
|-------|--------|-------|---------|
| 0 | 0 | Job-level outcomes only | `✓ Job: Completed successfully` |
| 0.5 | 2 | Phase headers (special level) | `  ─── Staging ───` |
| 1 | 4 | Phase outcomes, Source lines, phase progress | `    Source: file.mkv`, `✓   Staging: 8 files ready` |
| 2 | 8 | Per-file details, per-file outcomes, polling status | `        Tracks: 1 video`, `✓       Extracted: Dutch` |

**Marker alignment rule**: When an outcome line has a marker (✓/!/✗/↷), the marker replaces leading spaces to keep label alignment consistent with progress lines at the same level.

**Single-file example:**
```
[17:00:01]   ─── Staging ────────────────────────────────
[17:00:01]     Source: movie.mkv (4.2 GB)
[17:00:01]         Tracks: 1 video, 2 audio, 4 subtitles
[17:00:02]         Extracting: 2 subtitle tracks...
[17:00:03] ✓       Extracted: English, Dutch
[17:00:03]         Copying: to staging...
[17:00:05] ✓       Copied: movie.mkv
[17:00:05] ✓   Staging: 1 file ready (4.2 GB)
```

**Batch example (8 files):**

In batch mode, the `[n/N]` counter appears as a suffix on the `Source:` line. This keeps the structure identical to single-file mode while providing batch progress:

```
[17:00:01]   ─── Staging (8 files) ──────────────────────
[17:00:01]     Source: S01E01.mkv (847 MB) [1/8]
[17:00:01]         Tracks: 1 video, 1 audio, 1 subtitle
[17:00:02]         Extracting: 1 subtitle track...
[17:00:03] ✓       Extracted: Dutch
[17:00:03]         Copying: to staging...
[17:00:04] ✓       Copied: S01E01.mkv
[17:00:04]     Source: S01E02.mkv (856 MB) [2/8]
[17:00:04]         Tracks: 1 video, 1 audio, 2 subtitles
[17:00:05]         Copying: to staging...
[17:00:06] ✓       Copied: S01E02.mkv
           ...
[17:00:28] ✓   Staging: 8 files ready (6.5 GB)
```

**Finalize phase example:**
```
[17:00:28]   ─── Finalize ──────────────────────────────
[17:00:28] ✓   Cleanup: Staging folder removed
[17:00:28]     Log: C:\Logs\2024-01-15_movie_inception.log
[17:00:28]     Email: Sending notification...
[17:00:35] ✓   Email: Sent to user@example.com
[17:00:35] ✓ Job: Completed successfully
```

**Why this works:**
- `Source:` is a fixed-width label — filenames always align at the same column
- The `[n/N]` counter is optional metadata at the end, not part of the structure
- Indentation is identical between single-file and batch modes
- Markers replace leading spaces to maintain label alignment
- No complex prefix-width calculations needed

### Status Markers

| Marker | Meaning | Usage |
|--------|---------|-------|
| ✓ | Success | Action completed successfully |
| ! | Warning | Issue occurred but processing continued |
| ↷ | Skipped | No action taken (already done / not applicable) |
| ✗ | Error | Action failed |
| (space) | Neutral | Information, progress, or status |

**Markers indicate outcomes, not activities**:
```
# Good - marker on the outcome
[17:00:01]   Sending to Radarr...
[17:00:10] ✓ Added to library

# Bad - markers on everything
[17:00:01] ✓ Sending to Radarr...
[17:00:10] ✓ Added to library
```

### Section Headers

Group related operations visually:
```
[17:00:01] ─── Staging ────────────────────────────────
[17:00:05] ─── Subtitles ──────────────────────────────
[17:00:08] ─── Import (Radarr) ────────────────────────
```

**Section names**:
| Section | What it does |
|---------|--------------|
| **RAR Extraction** | Extract video files from RAR archives |
| **Staging** | MKV analysis, subtitle track extraction, remuxing, copying to staging folder |
| **Subtitles** | OpenSubtitles downloads, SubtitleEdit cleaning |
| **Import** | Send to Radarr/Medusa/Sonarr, wait for completion |
| **Cleanup** | Remove working files |
| **Passthrough** | Copy files without processing (non-media labels) |

**Naming guidelines**:
- Nouns, not verbs: `Staging` not `Staging Files`
- One word when possible
- User-recognizable terms

### Level of Detail

Console output should show meaningful steps within each phase. The user should understand what's happening without needing `-Verbose`.

**Staging (single file)**:
```
[17:00:01] ─── Staging ────────────────────────────────
[17:00:01]   Source: movie.mkv (2.1 GB)
[17:00:01]     Tracks: 1 video, 2 audio, 3 subtitles
[17:00:02]     Extracting: 2 subtitle tracks...
[17:00:03]   ✓ Extracted: English, Dutch
[17:00:03]     Copying to staging folder...
[17:00:05] ✓ Staging: Ready (2.1 GB)
```

**Staging (batch)**:
```
[17:00:01] ─── Staging (10 files) ─────────────────────
[17:00:01]   Source: S01E01.mkv (650 MB) [1/10]
[17:00:01]     Tracks: 1 video, 1 audio, 2 subtitles
[17:00:02]   ✓ Extracted: English
[17:00:02]   ✓ Copied
[17:00:03]   Source: S01E02.mkv (648 MB) [2/10]
[17:00:03]     Tracks: 1 video, 1 audio, 2 subtitles
[17:00:04]   ✓ Copied
           ...
[17:01:12] ✓ Staging: 10 files ready (6.2 GB)
```

**Subtitles**:
```
[17:00:05] ─── Subtitles ──────────────────────────────
[17:00:05]   Extracted: English, Dutch (from video)
[17:00:05]   External: Found 2 files in source folder
[17:00:05]   ↷ English (already have)
[17:00:05]   ✓ Dutch.forced copied
[17:00:06]   Wanted: English, Dutch — Have: English, Dutch
[17:00:06] ✓ Complete: All languages present
[17:00:06]     Cleaning 3 files with SubtitleEdit...
[17:00:08] ✓ Cleaned: 3 files with SubtitleEdit
```

**Subtitles (batch)**:

The Subtitles phase operates on the batch as a whole — one OpenSubtitles search, one SubtitleEdit run. Exceptions are surfaced inline as they occur:

```
[17:00:05] ─── Subtitles ──────────────────────────────
[17:00:05]   Extracted: 10 Dutch from video
[17:00:05]   OpenSubs: Searching for 10 missing English...
[17:00:08]   ! S01E03: English not available
[17:00:12]   ! S01E07: English not available
[17:00:15] ! OpenSubs: Downloaded 8 of 10 (2 unavailable)
[17:00:15]     Cleaning 18 files with SubtitleEdit...
[17:00:25] ✓ Cleaned: 18 files with SubtitleEdit
```

When all files succeed:
```
[17:00:05] ─── Subtitles ──────────────────────────────
[17:00:05]   Extracted: 10 Dutch from video
[17:00:05]   OpenSubs: Searching for 10 missing English...
[17:00:15] ✓ OpenSubs: Downloaded 10 subtitles (English)
[17:00:15]     Cleaning 20 files with SubtitleEdit...
[17:00:28] ✓ Cleaned: 20 files with SubtitleEdit
```

**Import**:
```
[17:00:08] ─── Import (Radarr) ────────────────────────
[17:00:08]   Sending to Radarr...
[17:00:10]   Status: Queued
[17:00:12]   Status: Processing...
[17:00:15] ✓ Radarr: Imported (7s)
[17:00:15] ✓ Cleanup: Staging folder removed
```

### What to Show at Each Phase

| Phase | Show | Don't Show (use Verbose) |
|-------|------|--------------------------|
| **Startup** | Configuration loaded | Tool versions, paths to executables, config file location |
| **RAR Extraction** | Source (file count, total size), extraction progress, extracted filename/size | Archive internals, per-file extraction progress, WinRAR command output |
| **Staging** | Source file name/size, track counts, extraction results | Repeated full paths (show once at job header or on error), codec internals, raw mkvmerge commands |
| **Subtitles** | Languages found/missing, sources (extracted/external/downloaded), cleanup results | Hash values, API request details, repeated file paths |
| **Import** | Target system, status updates, success/failure, duration | API URLs, command IDs, response bodies |
| **General** | Counts, sizes, durations, outcomes | Internal paths, configuration values, debug info |

### Progress Indication

For operations longer than 3–5 seconds, show the user something is happening. This is the main exception to "silence is golden": **preventing a perceived hang** is worth a single, well-chosen line.

**For polled operations (API commands, imports, long scans)**:
- Print immediately on **state change** (Queued → Started → Completed).
- If the state is unchanged, print a **heartbeat** at most every ~15 seconds.
- Always include **elapsed time** on progress and final outcome lines.
- Verbose may include every poll attempt; standard output should not spam repeats.

Example:

```
[17:00:01]   Radarr: Sending for import...
[17:00:03]   Status: Started (2s)
[17:00:18]   Status: Still running... (17s)
[17:00:33]   Status: Still running... (32s)
[17:00:41] ✓ Radarr: Imported (40s)
```

**For long-running single operations (RAR extraction, remuxing, hashing, copy/move, archive validation, cleanup)**:
- Print **one "starting" step line before the work begins** (use an ellipsis to signal waiting).
- If the operation can exceed ~30 seconds with no other output, optionally print a **heartbeat** at most every ~30 seconds (elapsed time only).
- Always follow with one terminal **outcome** line that states what happened and (when useful) includes counts and elapsed time.
- Avoid micro-progress ("5%… 6%…") unless the tool provides meaningful milestones.

Example:

```
[17:05:10]     Remuxing: Removing 35 unwanted subtitle tracks...
[17:06:57] ✓ Removed: 35 unwanted subtitles (1m47s)
```



### Batch Mode (Multiple Files)

**Channel note**: Batch output is primarily optimized for the **console operator** (technical). Email should summarize batches with counts and only highlight exceptions.

When processing a season pack or multiple files, the goal is to stay scannable while still surfacing problems.

**Default behavior**:
- One phase header with a file count: `Staging (10 files)`
- Use `Source:` label with `[n/N]` suffix for each file
- Same indentation as single-file mode (no special alignment)
- Per-file outcomes at level 1 (2 spaces)
- Show per-file detail only when it changes the outcome (missing subtitles, extraction failure, import skipped, etc.)
- End the phase with an **aggregate outcome** at level 0

Example:

```
[17:00:01] ─── Staging (10 files) ─────────────────────
[17:00:01]   Source: S01E01.mkv (6.5 GB) [1/10]
[17:00:01]     Tracks: 1 video, 2 audio, 4 subtitles
[17:00:02]   ✓ Extracted: English, Dutch
[17:00:05]   ✓ Copied
[17:00:05]   Source: S01E02.mkv (6.4 GB) [2/10]
[17:00:05]     Tracks: 1 video, 2 audio, 4 subtitles
[17:00:06]   ! Missing: Dutch (not in video)
[17:00:08]   ✓ Copied
           ...
[17:01:12] ✓ Staging: 10 files ready (64 GB)
```

**Phase granularity**: Staging operates per-file (each MKV needs individual analysis). Subtitles and Import operate on the batch as a whole, so their output is naturally summarized — surface exceptions inline as they occur, but don't repeat success for every file.

If batch output starts to feel noisy, move the per-file narration to `-Verbose` and keep standard output focused on exceptions and summaries.

### Informational Lines

Use unmarked (info) lines liberally to show what's happening:

```
[17:00:01]   Source: 3 files in folder
[17:00:01]   Largest: movie.mkv (4.2 GB)
[17:00:02]     Tracks: 1 video, 6 audio, 12 subtitles
[17:00:02]     Audio: English, Spanish, French, German, Italian, Japanese
[17:00:02]     Subtitles: 12 tracks (4 languages, some forced/SDH)
```

This level of detail helps users understand what they're working with and confirms the system is analyzing correctly.

### Verbose Mode

`-Verbose` is for troubleshooting and power users. It adds the layer beneath standard output:

| Standard | Verbose adds |
|----------|--------------|
| `Sending to Radarr...` | `POST http://192.168.1.10:7878/api/v3/command` |
| `Status: Processing...` | `Command ID: 1881442, checking every 2s` |
| `Imported successfully` | `Response: 200 OK, imported 1 file` |
| `Staging folder removed` | `Deleted: C:\Processing\Movie\Inception (2010)` |

**Verbose adds context, not repetition**:
- Do **not** echo standard lines in verbose unless you're adding new information.
- Prefer "how/why" details: request type, command IDs, selected tracks, decision reasons, retry logic.
- Rate-limit repetitive verbose in loops when it stops adding value (e.g., log only on status change unless debugging).

**Deduplicate environment noise**:
- Tool versions: once per run (startup).
- Hostname/IP resolution: once per job per service (cache and reuse).
- Dependency internals: suppress third-party verbose/info unless explicitly enabled.


**External tool versions** should be logged at startup or first use. This is invaluable for troubleshooting issues that only occur with specific versions:

```
VERBOSE: WinRAR: 6.24 (C:\Program Files\WinRAR\rar.exe)
VERBOSE: MKVToolNix: 81.0 (C:\Program Files\MKVToolNix\mkvmerge.exe)
VERBOSE: SubtitleEdit: 4.0.4 (C:\Program Files\Subtitle Edit\SubtitleEdit.exe)
VERBOSE: ffprobe: 6.1.1 (C:\Tools\ffmpeg\bin\ffprobe.exe)
```

**API and network details**:
```
VERBOSE: Resolved download.home.lan → 192.168.2.11
VERBOSE: POST /api/v3/command (98 bytes)
VERBOSE: Response: 201 Created, Command ID: 1881442
VERBOSE: Polling command status...
VERBOSE: Attempt 1: status=queued
VERBOSE: Attempt 2: status=started
VERBOSE: Attempt 3: status=completed
```

Verbose output uses the `VERBOSE:` prefix (PowerShell standard) and does **not** appear in email.

---

## Filesystem Logs

Stagearr produces a log artifact on disk for troubleshooting and sharing. This log is **not** the same thing as console output, and it is **not** a substitute for the email summary.

### Filesystem log format (plain text only)

**The filesystem log is the definitive run record** for operators and troubleshooting.  
It is **plain text** (no HTML), written in **UTF‑8**, with **no ANSI color codes**.

Why:
- Fast to search/grep
- Easy to copy/paste into chat or issues
- Stable across environments (no rendering quirks)

#### Requirements

- **One log file per run** (including early exits, lock contention, and failures).
- **Include the verbose layer by default** (the log should contain everything you'd see with `-Verbose`, even if the console run wasn't verbose).
- **Consistent structure**: each line should include at least `time`, `level`, and `phase` (or an equivalent prefix).
- **No secrets**: never write API keys, tokens, credentials, or full request/response payloads that may contain them.

#### Content rules

- On failures, the log must include:
  - The **phase** that failed
  - A **human summary** of the reason
  - The **next step** (what to check or retry)
- Long-running jobs should include **timings** per phase and total duration.
- Repeated/polling messages should be **rate-limited** (see polling policy) to keep the log usable.

### Lifecycle rules

- Create a log file for **every run**, including early exits and lock contention.
- Always print the log path near the end of console output:
  - `Log: <path>`
- Email should reference the log (attach it or tell the user where it is).

---

## PowerShell Output Rules

These rules keep output testable, pipe-safe, and consistent with PowerShell expectations:

### Use the right streams
- **Info / progress / success narration**: Information stream (so it doesn't pollute pipelines)
- **Warnings**: Warning stream
- **Errors**: Error stream (and terminate for hard failures)
- **Verbose details**: Verbose stream (`-Verbose`)
- **Debug-only dev noise**: Debug stream (`-Debug`)

### Pipeline safety
- Human-facing text must not be emitted on the success output stream by default.
- If the script ever needs to output *data objects*, those objects should be clean and separate from all human text.

### Renderer boundaries
- Business logic should not write directly to the host.
- Console styling (color, Unicode lines, icons) belongs in the console renderer only, and must degrade cleanly under `-NoColor` and `-Ascii`.

---

## Email Notifications

Email is the **asynchronous operator dashboard**. It's read after the fact (often on a phone), so it must be compact and verdict-first — but it is written for the same tech‑savvy audience as the console. Using your domain terms (Radarr, Medusa, OpenSubtitles, etc.) is expected.

### Design Constraints

- **Glanceable**: Answer "did it work?" in under 2 seconds
- **Mobile-friendly**: Readable on a phone without zooming
- **Triage-oriented**: Show outcomes, counts, and exceptions — not step-by-step narration
- **Self-contained for triage**: Makes sense without the console and always includes the filesystem log path for deep detail

### Subject Line

The subject line may be all the user sees (notification banners, inbox preview). Make it count.

| Outcome | Pattern | Example |
|---------|---------|---------|
| Success | `{Category}: {Name}` | `Movie: Inception (2010)` |
| Warning | `{Category}: {Name}` | `TV: Breaking Bad S01` |
| Failure | `Failed: {Name}` | `Failed: Inception (2010)` |
| Skipped | `Skipped: {Name}` | `Skipped: Inception (2010)` |

**Keep under 50 characters** — mobile truncates aggressively.

### Email Subject Templates

Email subjects support configurable formatting using presets or custom templates. This helps differentiate downloads when the same content is fetched multiple times (e.g., quality upgrade, different release group).

#### Preset Styles

| Style | Example | Use Case |
|-------|---------|----------|
| `detailed` | `Movie: Inception (2010) [2160p UHD-GROUP]` | Default, maximum differentiation |
| `quality` | `Movie: Inception (2010) [2160p]` | Resolution focus |
| `source` | `Movie: Inception (2010) [BluRay-GROUP]` | Source + group |
| `group` | `Movie: Inception (2010) [GROUP]` | Group only |
| `hash` | `Movie: Inception (2010) [a1b2]` | Always unique (torrent hash) |
| `none` | `Movie: Inception (2010)` | Original behavior |

#### Custom Templates

Set `subjectStyle: "custom"` and define `subjectTemplate` with placeholders:

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `{result}` | Status prefix (empty/Failed:/Skipped:) | `Failed: ` |
| `{label}` | Download label | `Movie`, `TV` |
| `{name}` | Friendly name | `Inception (2010)` |
| `{resolution}` | Screen size | `2160p`, `1080p` |
| `{source}` | Source type | `WEB`, `BluRay`, `Remux` |
| `{group}` | Release group | `NTb`, `CiNEPHiLES` |
| `{service}` | Streaming service | `NF`, `AMZN`, `HMAX` |
| `{hash4}` | Short torrent hash | `a1b2` |

**Example custom templates:**
- `{result}{name} [{service} {resolution}]` → `Stranger Things S05 [NF 2160p]`
- `{result}{name} -{group}` → `Inception (2010) -CiNEPHiLES`

Configure via `notifications.email.subjectStyle` and `notifications.email.subjectTemplate` in config.toml.

#### Smart Cleanup

When placeholders have no value, cleanup rules apply automatically:
- Unfilled placeholders like `{group}` are removed
- Empty brackets `[]` are removed
- Orphaned dashes `[-]`, `[- ]` are cleaned
- Multiple spaces are collapsed

```
Template: "{label}: {name} [{resolution} {source}-{group}]"
Missing:  source, group
Before:   "Movie: Inception (2010) [2160p -]"
After:    "Movie: Inception (2010) [2160p]"
```

### Color Usage

Color is a powerful signal — use it sparingly and consistently.

| Element | Color | Hex |
|---------|-------|-----|
| Success status badge | Green | `#22c55e` |
| Warning status badge | Amber | `#f59e0b` |
| Failure status badge | Red | `#ef4444` |
| Skipped status badge | Gray | `#6b7280` |
| Section accents | Slate | `#475569` |
| Background | Dark | `#1e293b` |
| Card background | Darker | `#0f172a` |
| Text primary | White | `#f8fafc` |
| Text secondary | Gray | `#94a3b8` |

**Only the status badge gets the outcome color.** When everything is highlighted, nothing stands out.

### Email Template

The email template uses a modern dark theme optimized for mobile viewing:

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │                                             │   │
│   │            ✓ SUCCESS                        │   │  ← Green badge
│   │                                             │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   Inception (2010)                                  │  ← Title large
│   Movie • Radarr                                    │  ← Category • Target
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  DETAILS                                    │   │
│   ├─────────────────────────────────────────────┤   │
│   │  Files       1 video (4.2 GB)               │   │
│   │  Subtitles   ✓ English, Dutch               │   │
│   │  Import      Imported to library            │   │
│   │  Duration    47 seconds                     │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │  ← Only if warnings
│   │  NOTES                                      │   │
│   ├─────────────────────────────────────────────┤   │
│   │  • Dutch subtitle downloaded from           │   │
│   │    OpenSubtitles                            │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   Log: C:\Logs\2024-01-15_movie_inception.log      │  ← Always show
│                                                     │
│   ─────────────────────────────────────────────    │
│   Stagearr v2.0.0                             │  ← Footer
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Status badges**:
```
┌─────────────────────┐
│      ✓ SUCCESS      │  Green background (#22c55e), white text
└─────────────────────┘

┌─────────────────────┐
│      ! WARNING      │  Amber background (#f59e0b), white text
└─────────────────────┘

┌─────────────────────┐
│      ✗ FAILED       │  Red background (#ef4444), white text
└─────────────────────┘

┌─────────────────────┐
│      ↷ SKIPPED      │  Gray background (#6b7280), white text
└─────────────────────┘
```

**Batch mode email** (season pack):
```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │            ! WARNING                        │   │  ← Amber if any issues
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   Breaking Bad Season 1                             │
│   TV • Medusa                                       │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  DETAILS                                    │   │
│   ├─────────────────────────────────────────────┤   │
│   │  Files       7 episodes (18.4 GB)           │   │
│   │  Subtitles   ✓ English (7), Dutch (7)       │   │
│   │  Import      Skipped (quality exists)       │   │
│   │  Duration    2m 34s                         │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  NOTES                                      │   │
│   ├─────────────────────────────────────────────┤   │
│   │  • Skipped 7 files (Quality exists)         │   │  ← Episode-level detail
│   └─────────────────────────────────────────────┘   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Batch mode email** (partial import with episode detail):
```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │            ! WARNING                        │   │  ← Amber for partial import
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   Sleepers NL S02                                   │
│   TV • Medusa                                       │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  DETAILS                                    │   │
│   ├─────────────────────────────────────────────┤   │
│   │  Files       8 episodes (6.5 GB)            │   │
│   │  Subtitles   ✓ Dutch (8), English (8)       │   │
│   │  Import      Imported 1 file                │   │
│   │  Duration    1m 05s                         │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  NOTES                                      │   │
│   ├─────────────────────────────────────────────┤   │
│   │  • Imported S02E08                          │   │  ← Single episode inline
│   │  • Skipped 6 files (Quality exists)         │   │  ← >3 episodes = count
│   │  • Aborted S02E07 (Archived)                │   │  ← Single episode inline
│   └─────────────────────────────────────────────┘   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Episode-level formatting rules** (Notes section):
- ≤3 episodes: Show inline (e.g., "Imported S02E08" or "Skipped S02E01-E03")
- >3 episodes: Show count (e.g., "Skipped 6 files")
- Consistent with console output (same threshold, same format)
- Reason in parentheses: "(Quality exists)", "(Archived)"

**Failure email** structure:
```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │            ✗ FAILED                         │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   Inception (2010)                                  │
│   Movie • Radarr                                    │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  WHAT HAPPENED                              │   │
│   ├─────────────────────────────────────────────┤   │
│   │  Phase       Import                         │   │
│   │  Error       Folder not accessible          │   │
│   │  Path        \\server\movies\Inception      │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  WHAT TO CHECK                              │   │
│   ├─────────────────────────────────────────────┤   │
│   │  • Is the network drive mounted?            │   │
│   │  • Does Radarr have write permission?       │   │
│   │  • Is Radarr service running?               │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   Log: C:\Logs\2024-01-15_movie_inception.log      │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### What to Include

✓ **Always show**:
- Status badge (most prominent element)
- What was processed (name, label/category)
- Import target (Radarr/Medusa/etc.)
- Final outcome
- Duration (confirms it actually ran)
- Filesystem **log path** (the definitive record)

✓ **Show when relevant**:
- Subtitle status (languages present/downloaded/missing)
- File count and total size (for batches)
- Notes section (warnings, skips, downloads)

✓ **Show on failure**:
- What phase failed
- Error description (plain language)
- Actionable suggestions

✗ **Avoid in email** (move to log/verbose):
- Raw technical identifiers (hashes, command IDs, request URLs)
- Progress/poll spam ("Processing…", repeated status lines)
- Stack traces and full exception dumps
- Huge file lists or per-episode narration for season packs
- Third‑party module chatter

### Passthrough Mode Email

For non-media labels (software, ebooks, etc.):

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │            ✓ SUCCESS                        │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   Adobe Photoshop 2024                              │
│   software • Passthrough                            │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  DETAILS                                    │   │
│   ├─────────────────────────────────────────────┤   │
│   │  Files       23 files (4.8 GB)              │   │
│   │  Action      Copied to output folder        │   │
│   │  Duration    12 seconds                     │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## Writing Guidelines

### Plain Language

Technical accuracy matters less than user understanding.

| Technical | Plain |
|-----------|-------|
| `Process terminated with signal SIGKILL` | `Process was stopped unexpectedly` |
| `Socket connection refused on port 7878` | `Couldn't connect to Radarr` |
| `JSON parse error at position 0` | `Received invalid response from server` |
| `EPERM: operation not permitted` | `Permission denied` |
| `SSL certificate verify failed` | `Secure connection failed - certificate issue` |

### Specific Over Vague

Vague messages create anxiety. Specific messages create understanding.

```
# Vague (bad)
Files processed
Subtitles handled
Import complete

# Specific (good)
2 files converted (4.2 GB)
Subtitles: English, Dutch
Added to Radarr: "Inception (2010)"
```

### Quantities and Measurements

- Use proper pluralization: `1 file`, `3 files` (never `file(s)`)
- Include units: `2.1 GB`, `13 seconds`
- Be precise when it matters: `2 of 3 subtitles found`
- Round appropriately: `2.1 GB` not `2,147,483,648 bytes`

### Error Messages

Good error messages have three parts:

1. **What** happened (the symptom)
2. **Why** it happened (if known)
3. **What to do** (if actionable)

```
# Just what (not helpful)
Import failed

# What + why (better)
Import failed: folder not found

# What + why + action (best)
Import failed: Radarr couldn't access the folder.
Check that \\server\movies is mounted and accessible.
```

---

## Accessibility Considerations

### Don't Rely on Color Alone

Color-blind users may not distinguish red/green. Always pair color with:
- Text labels: "SUCCESS" / "FAILED"
- Icons or markers: ✓ / ✗
- Position: Status badge always at top

### Screen Reader Compatibility

Email HTML should be semantic:
- Use proper table headers
- Avoid images for text
- Ensure logical reading order

### Respect System Preferences

Console output should:
- Work without color (`-NoColor` flag)
- Support ASCII fallback for legacy terminals
- Not depend on specific fonts or Unicode support

---

## Decision Framework

When adding new output to any part of the system, answer these questions:

### 1. Does the user need this?

If removing this output would go unnoticed by 90% of users, make it verbose-only or remove it entirely.

### 2. Is this an outcome or process?

- **Outcomes** get markers (✓ ! ✗)
- **Process steps** get no marker or aren't shown at all

### 3. Would an operator understand this in a quick scan?

If not, tighten the wording until it's immediately clear.

### 4. Should this be in email?

Would this be useful to someone reading on their phone 2 hours from now? If not, console-only.

### 5. Am I explaining success or failure?

- Success needs minimal explanation
- Failure needs what/why/what-to-do

### 6. Have I earned this user's attention?

Every notification, every line of output, is asking for a small piece of someone's day. Make it worth their time.


### 7. Will this spam in loops or polling?

If this line can repeat many times, it must be rate-limited (heartbeat) or moved to `-Verbose`.

### 8. Is this duplicated across levels?

Standard output states the **what** (and outcome). Verbose adds the **how/why**. Avoid repeating the same sentence in both.

### 9. Is this "ours" and user-safe?

- Don't leak third‑party module chatter (dependency verbose/info) into our console output.
- Email is an operator dashboard: keep it concise; domain terms are OK. Avoid low-level internals (hashes/tokens/command IDs). Include paths only when actionable, and always include the filesystem log path.

---

## Examples

> Examples in this section are illustrative, not strict templates. Real output will vary by label, tooling, and runtime.


### Perfect Success Flow

**Console**:
```
[17:00:01]   ─── Staging ────────────────────────────────
[17:00:01]     Source: Inception.2010.1080p.BluRay.mkv (4.2 GB)
[17:00:01]         Tracks: 1 video, 2 audio, 4 subtitles
[17:00:02]         Extracting: 2 SRT subtitle tracks...
[17:00:03] ✓       Extracted: English, Dutch
[17:00:03]         Copying: to staging...
[17:00:08] ✓       Copied: Inception (2010).mkv
[17:00:08] ✓   Staging: 1 file ready (4.2 GB)
[17:00:08]   ─── Subtitles ──────────────────────────────
[17:00:08]     Extracted: 2 subtitles from video
[17:00:08]     Cleaning: 2 files with SubtitleEdit...
[17:00:10] ✓   Cleaned: 2 files with SubtitleEdit
[17:00:10] ✓   Subtitles: English, Dutch
[17:00:10]   ─── Import (Radarr) ────────────────────────
[17:00:10]     Radarr: Sending for import...
[17:00:12]         Status: Processing... (2s)
[17:00:15] ✓   Radarr: Imported (5s)
[17:00:15]   ─── Finalize ──────────────────────────────
[17:00:15] ✓   Cleanup: Staging folder removed
[17:00:15]     Log: C:\Logs\2024-01-15_movie_inception.log
[17:00:15]     Email: Sending notification...
[17:00:22] ✓   Email: Sent to user@example.com
[17:00:22] ✓ Job: Completed successfully
```

**Email subject**: `Movie: Inception (2010)`

**Email body**: Dark themed card with green SUCCESS badge, details section showing files/subtitles/import/duration, and log path.

### Helpful Failure Flow

**Console**:
```
[17:00:01]   ─── Staging ────────────────────────────────
[17:00:01]     Source: Inception.2010.1080p.BluRay.mkv (4.2 GB)
[17:00:01]         Tracks: 1 video, 2 audio, 4 subtitles
[17:00:03] ✓       Extracted: English, Dutch
[17:00:03]         Copying: to staging...
[17:00:08] ✓       Copied: Inception (2010).mkv
[17:00:08] ✓   Staging: 1 file ready (4.2 GB)
[17:00:08]   ─── Subtitles ──────────────────────────────
[17:00:08]     Cleaning: 2 files with SubtitleEdit...
[17:00:10] ✓   Cleaned: 2 files with SubtitleEdit
[17:00:10] ✓   Subtitles: English, Dutch
[17:00:10]   ─── Import (Radarr) ────────────────────────
[17:00:10]     Radarr: Sending for import...
[17:00:15] ✗   Radarr: Import failed (5s)
[17:00:15]         Reason: Folder not accessible
[17:00:15]         Path: \\server\movies\Inception (2010)
[17:00:15]   ─── Finalize ──────────────────────────────
[17:00:15] ✓   Cleanup: Staging folder removed
[17:00:15]     Log: C:\Logs\2024-01-15_movie_inception.log
[17:00:15]     Email: Sending notification...
[17:00:22] ✓   Email: Sent to user@example.com
[17:00:22] ✗ Job: Failed
```

**Email subject**: `Failed: Inception (2010)`

**Email body**: Dark themed card with red FAILED badge, "What Happened" section with phase/error/path, "What to Check" section with troubleshooting suggestions.

### Partial Success (Missing Subtitles)

**Console**:
```
[17:00:05]   ─── Subtitles ──────────────────────────────
[17:00:05]     Extracted: 1 subtitle from video
[17:00:05]     OpenSubs: Searching for Dutch...
[17:00:08] !   OpenSubs: Dutch not available
[17:00:08]     Cleaning: 1 file with SubtitleEdit...
[17:00:09] ✓   Cleaned: 1 file with SubtitleEdit
[17:00:09] !   Missing: Dutch
[17:00:09] ✓   Subtitles: English
[17:00:09]   ─── Import (Radarr) ────────────────────────
[17:00:09]     Radarr: Sending for import...
[17:00:14] ✓   Radarr: Imported (5s)
[17:00:14]   ─── Finalize ──────────────────────────────
[17:00:14] ✓   Cleanup: Staging folder removed
[17:00:14]     Log: C:\Logs\2024-01-15_movie_inception.log
[17:00:22] ✓   Email: Sent to user@example.com
[17:00:22] ! Job: Completed with warnings
```

**Email subject**: `Movie: Inception (2010)`

**Email body**: Success card with green badge, but Notes section shows "Missing: Dutch (not available on OpenSubtitles)"

### RAR Extraction Flow

RAR extraction is its own phase, separate from Staging. Show what's being extracted and provide a starting line so the user knows work is happening:

**Console**:
```
[17:00:01]   ─── RAR Extraction ─────────────────────────
[17:00:01]     Source: 47 RAR files (4.2 GB total)
[17:00:01]     Extracting with WinRAR...
[17:00:17] ✓   Extracted: Inception.2010.1080p.BluRay.mkv (4.2 GB)
[17:00:17]   ─── Staging ────────────────────────────────
[17:00:17]     Source: Inception.2010.1080p.BluRay.mkv (4.2 GB)
[17:00:17]         Tracks: 1 video, 2 audio, 4 subtitles
[17:00:18]         Extracting: 2 SRT subtitle tracks...
[17:00:19] ✓       Extracted: English, Dutch
[17:00:19]         Copying: to staging...
[17:00:24] ✓       Copied: Inception.2010.1080p.BluRay.mkv
[17:00:24] ✓   Staging: 1 file ready (4.2 GB)
```

### Passthrough Mode

**Console**:
```
[17:00:01]   ─── Passthrough (Copy) ────────────────────
[17:00:01]     Copying: to destination...
[17:00:03] ✓   Copied: 15 files (842 MB)
[17:00:03]   ─── Import ────────────────────────────────
[17:00:03] ↷   Import: Passthrough mode (no import configured)
[17:00:03]   ─── Finalize ──────────────────────────────
[17:00:03]     Cleanup: Skipped (no staging folder)
[17:00:03]     Log: C:\Logs\2024-01-15_software_appname.log
[17:00:03]     Email: Sending notification...
[17:00:10] ✓   Email: Sent to user@example.com
[17:00:10] ✓ Job: Completed successfully
```

**Email subject**: `software: AppName`

**Email body**: Success card showing files copied, action "Passthrough", no import details.

### Season Pack Batch

**Console**:
```
[17:00:01]   ─── Staging (8 files) ──────────────────────
[17:00:01]     Source: S02E01.mkv (847 MB) [1/8]
[17:00:01]         Tracks: 1 video, 1 audio, 1 subtitle
[17:00:02]         Extracting: 1 subtitle track...
[17:00:03] ✓       Extracted: Dutch
[17:00:03]         Copying: to staging...
[17:00:04] ✓       Copied: S02E01.mkv
[17:00:04]     Source: S02E02.mkv (856 MB) [2/8]
[17:00:04]         Tracks: 1 video, 1 audio, 2 subtitles
[17:00:05]         Copying: to staging...
[17:00:06] ✓       Copied: S02E02.mkv
           ...
[17:00:28] ✓   Staging: 8 files ready (6.5 GB)
[17:00:28]   ─── Subtitles ──────────────────────────────
[17:00:28]     Extracted: 8 subtitles from video
[17:00:28]     OpenSubs: Searching for 8 missing English subtitles...
[17:00:38] ✓   OpenSubs: Downloaded 8 subtitles
[17:00:38]     Cleaning: 16 files with SubtitleEdit...
[17:00:45] ✓   Cleaned: 16 files with SubtitleEdit
[17:00:45] ✓   Subtitles: English (8), Dutch (8)
[17:00:45]   ─── Import (Medusa) ────────────────────────
[17:00:45]     Medusa: Importing...
[17:00:50]         Status: Processing (5s)
[17:00:55] ✓   Medusa: Imported S02E08 (10s)
[17:00:55] !   Medusa: Skipped 6 files (Quality exists)
[17:00:55] !   Medusa: Aborted S02E07 (Archived)
[17:00:55]         Hint: Some episodes are archived in Medusa - change status to Wanted or Skipped
[17:00:55]   ─── Finalize ──────────────────────────────
[17:00:55] ✓   Cleanup: Staging folder removed
[17:00:55]     Log: C:\Logs\2024-12-24_tv_sleepers-nl-s02.log
[17:00:55]     Email: Sending notification...
[17:01:02] ✓   Email: Sent to user@example.com
[17:01:02] ! Job: Completed with warnings
```

**Email subject**: `TV: Sleepers NL S02`

**Email body**: Warning card (amber), details showing 8 episodes processed, subtitles complete, Notes section with episode-level detail:
- "Imported S02E08" (single episode inline)
- "Skipped 6 files (Quality exists)" (>3 episodes = count)
- "Aborted S02E07 (Archived)" (single episode inline)

---

## Summary

| Principle | Application |
|-----------|-------------|
| Lead with outcome | Status badge and subject line tell the story |
| One glance is enough | Visual hierarchy with indentation, not walls of text |
| Explain failures, not successes | Success is minimal; failure is detailed |
| Human language | Plain language; domain terms are OK (Radarr/Medusa/OpenSubtitles), avoid low-level internals |
| Silence is golden | Every line must earn user attention |
| Accessibility | Color + text + icons; works for everyone |
| Reduce fatigue | Summarize batch phases, show exceptions only |

The best output is the output users don't have to think about.
