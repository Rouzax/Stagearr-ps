# Stagearr Landing Page Design

**Date:** 2026-03-12
**Type:** GitHub Pages hero/landing page

## Overview

Single-page landing site for Stagearr, deployed via GitHub Pages. Target audience: media automation enthusiasts already using the *arr stack and qBittorrent. Bold/modern aesthetic (Linear/Vercel-inspired) with dark theme matching the existing email palette.

## Tech Approach

- Single `index.html` with inline CSS — no build tools, no frameworks
- CSS animations (`@keyframes`) + `IntersectionObserver` for scroll-triggered reveals
- Responsive: horizontal layouts on desktop, stacked on mobile
- Color system from existing email palette:
  - Backgrounds: `#0f172a` (page), `#1e293b` (cards)
  - Accents: `#22c55e` (green), `#f59e0b` (amber), `#ef4444` (red), `#60a5fa` (blue)
  - Text: `#f8fafc` (primary), `#94a3b8` (secondary), `#64748b` (muted)
  - Borders: `#334155`

## Sections

### 1. Hero

- **Headline:** "Torrent completes → library ready"
- **Subheadline:** "Automated post-processing for qBittorrent. Extract, remux, subtitle, import — zero manual steps."
- Animated pipeline teaser: horizontal line with icons/dots flowing `qBittorrent → Extract → Process → Import → Notify`
- Two CTAs: "Get Started" (docs) + "View on GitHub" (repo)
- Radial gradient glow (green/blue) behind headline

### 2. Pipeline Visualization

- **Title:** "Six phases. Fully automated."
- Horizontal flow (vertical on mobile) of 5 phase cards connected by animated dashed lines:
  - Stage → Video → Subtitles → Import → Notify
- Each card: icon, phase name, one-line description
- Scroll-triggered sequential left-to-right animation
- Tagline below: "Crash-safe. File-backed queue with global locking survives reboots."

### 3. Feature Cards

- **Title:** "Everything between download and library"
- 2×3 grid:
  1. **RAR Extraction** — Automatically detects and extracts nested archives
  2. **Video Processing** — MP4→MKV remux, subtitle track stripping via MKVToolNix
  3. **Subtitle Intelligence** — Extract, download from OpenSubtitles, clean with SubtitleEdit
  4. **Multi-Server Import** — Radarr, Sonarr, and Medusa — ManualImport API with polling
  5. **Rich Notifications** — Dark-themed HTML emails with posters, ratings, and status
  6. **Label Routing** — qBittorrent labels automatically route to the right server
- Dark card background (`#1e293b`), border glow on hover (green accent), slight lift

### 4. Email Showcase

- **Title:** "Know exactly what happened"
- Three live HTML mockups (not screenshots) side by side, stacked on mobile:
  1. **Success** (green) — movie poster, IMDb/RT/MC ratings, details card
  2. **Warning** (amber) — TV show, details + Notes section (missing subtitles)
  3. **Failed** (red) — no poster, "What Happened" + "What to Check" sections
- Each in an elevated card with status-color glow, subtle hover tilt
- Content uses real titles pulled from live Radarr/Sonarr libraries
- Tagline: "Metadata powered by OMDb — posters, ratings, genres, and IMDb links."

### 5. Integration Logos

- **Title:** "Plugs into your stack"
- Horizontal row of SVG logos: qBittorrent, Radarr, Sonarr, Medusa, OpenSubtitles, OMDb, MKVToolNix, WinRAR
- Muted/grayscale, brighten on hover

### 6. Footer

- Links: Get Started (docs), GitHub (repo), Documentation (wiki)
- Version number (from manifest)
- MIT License note

## Images Needed

- Movie poster for success email mockup (from Radarr library)
- TV show poster for warning email mockup (from Sonarr library)
- SVG logos for integration strip (qBittorrent, Radarr, Sonarr, Medusa, OpenSubtitles, OMDb, MKVToolNix, WinRAR)

## Deployment

GitHub Pages from a `docs/` folder or dedicated `gh-pages` branch.
