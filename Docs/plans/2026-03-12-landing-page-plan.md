# Stagearr Landing Page Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a single-page GitHub Pages landing site for Stagearr with hero, pipeline visualization, feature cards, email mockups, integration logos, and footer.

**Architecture:** Single `index.html` with inline CSS. No frameworks or build tools. CSS animations with `IntersectionObserver` for scroll-triggered reveals. Dark theme from the existing email color palette. Responsive (mobile-first).

**Tech Stack:** HTML5, CSS3 (custom properties, grid, flexbox, keyframes), vanilla JS (IntersectionObserver only)

---

### Task 1: Project Setup — Create index.html with CSS Foundation

**Files:**
- Create: `docs/index.html`

**Step 1: Create the HTML shell with CSS custom properties and base styles**

Create `docs/index.html` with:
- HTML5 doctype, viewport meta, Open Graph meta tags
- CSS custom properties for the color system:
  - `--bg-page: #0f172a`, `--bg-card: #1e293b`, `--bg-card-hover: #253347`
  - `--green: #22c55e`, `--amber: #f59e0b`, `--red: #ef4444`, `--blue: #60a5fa`
  - `--text-primary: #f8fafc`, `--text-secondary: #94a3b8`, `--text-muted: #64748b`
  - `--border: #334155`
  - `--imdb-yellow: #f5c518`, `--tomato-red: #fa320a`, `--metacritic-green: #66cc33`
- CSS reset, body styles (font: Inter/system-ui, bg: page color, color: primary)
- Utility classes for fade-in animations (`[data-animate]` with IntersectionObserver)
- Responsive breakpoints: 768px (tablet), 1024px (desktop)
- Basic section padding/max-width container (1200px centered)

**Step 2: Add IntersectionObserver script**

At bottom of body, add vanilla JS:
```javascript
document.addEventListener('DOMContentLoaded', () => {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add('visible');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.1 });
  document.querySelectorAll('[data-animate]').forEach(el => observer.observe(el));
});
```

**Step 3: Verify base renders**

Open in browser, confirm dark background, no errors in console.

**Step 4: Commit**

```bash
git add docs/index.html
git commit -m "feat: scaffold landing page with CSS foundation"
```

---

### Task 2: Hero Section

**Files:**
- Modify: `docs/index.html`

**Step 1: Add hero HTML**

After `<body>`, add hero section:
- Full-viewport-height section with centered content
- `<h1>` "Torrent completes → library ready" (large bold, ~3.5rem desktop)
- `<p>` subtitle: "Automated post-processing for qBittorrent. Extract, remux, subtitle, import — zero manual steps."
- Animated pipeline teaser: 5 inline items with connecting lines: `qBittorrent → Extract → Process → Import → Notify` — small pills/badges with a flowing dot animation
- Two CTA buttons: "Get Started" (primary, green bg) + "View on GitHub" (outline, border only)
- Background: radial gradient glow (green/blue, subtle, centered behind headline)

**Step 2: Add hero CSS**

- `.hero` — min-height: 100vh, display: flex, align-items: center, justify-content: center, text-align: center, position: relative
- `.hero h1` — font-size clamp(2rem, 5vw, 3.75rem), font-weight 800, letter-spacing: -0.02em, line-height 1.1
- `.hero .subtitle` — font-size 1.25rem, color: var(--text-secondary), max-width 600px, margin: 1.5rem auto
- `.hero-glow` — position absolute, width 600px, height 400px, background radial gradient of green/blue at 10% opacity, filter blur(80px), z-index 0
- `.pipeline-teaser` — flex row, gap, small text, items connected by animated dashed border or gradient line
- `.pipeline-teaser .dot` — animated green dot moving left-to-right using keyframes
- `.cta-group` — flex row, gap 1rem
- `.btn-primary` — bg green, white text, rounded-full, px 2rem, py 0.75rem, font-weight 600, hover: brightness
- `.btn-outline` — border 1px var(--border), text-secondary, same shape, hover: border-color white
- Mobile: stack CTAs vertically, reduce heading size

**Step 3: Commit**

```bash
git add docs/index.html
git commit -m "feat: add hero section with animated pipeline teaser"
```

---

### Task 3: Pipeline Visualization Section

**Files:**
- Modify: `docs/index.html`

**Step 1: Add pipeline HTML**

Section with:
- Section title: "Six phases. Fully automated." (centered, bold)
- Horizontal flex container with 5 phase cards + connecting arrows:
  1. Stage — "Copy & extract files to staging"
  2. Video — "RAR extract, MP4→MKV remux"
  3. Subtitles — "Extract, download & clean"
  4. Import — "Send to Radarr, Sonarr or Medusa"
  5. Notify — "Email with posters & ratings"
- Each card: icon (emoji), phase name (bold), description (small muted text)
- Between cards: SVG arrow or `→` character with animated dash
- Below pipeline: tagline "Crash-safe. File-backed queue with global locking survives reboots." (muted, centered)
- All cards use `data-animate` with staggered delay (`style="--delay: 0.1s"` etc.)

**Step 2: Add pipeline CSS**

- `.pipeline` — display flex, justify-content center, align-items stretch, gap 0
- `.pipeline-card` — bg var(--bg-card), border 1px var(--border), rounded 12px, padding 1.5rem, text-align center, min-width 160px, flex 1
- `.pipeline-card .icon` — font-size 2rem, margin-bottom 0.5rem
- `.pipeline-card h3` — font-size 1rem, font-weight 700
- `.pipeline-card p` — font-size 0.875rem, color var(--text-muted)
- `.pipeline-arrow` — display flex, align-items center, color var(--text-muted), font-size 1.5rem, padding 0 0.5rem
- Staggered animation: `[data-animate].visible { animation: fadeSlideUp 0.5s ease forwards; animation-delay: var(--delay, 0s); }`
- Mobile: flex-direction column, arrows rotate 90deg or become `↓`

**Step 3: Commit**

```bash
git add docs/index.html
git commit -m "feat: add pipeline visualization section"
```

---

### Task 4: Feature Cards Section

**Files:**
- Modify: `docs/index.html`

**Step 1: Add feature cards HTML**

Section with:
- Title: "Everything between download and library"
- 2×3 CSS grid of cards:

| Icon | Title | Description |
|------|-------|-------------|
| 📦 | RAR Extraction | Detects and extracts nested archives automatically |
| 🎬 | Video Processing | MP4→MKV remux and subtitle track stripping via MKVToolNix |
| 💬 | Subtitle Intelligence | Extract from MKV, download from OpenSubtitles, clean with SubtitleEdit |
| 📥 | Multi-Server Import | Radarr, Sonarr, and Medusa via ManualImport API with polling |
| 📧 | Rich Notifications | Dark-themed HTML emails with posters, ratings, and status badges |
| 🏷️ | Label Routing | qBittorrent labels automatically route to the right media server |

Each card uses `data-animate`.

**Step 2: Add feature cards CSS**

- `.features-grid` — display grid, grid-template-columns repeat(3, 1fr), gap 1.5rem
- `.feature-card` — bg var(--bg-card), border 1px var(--border), rounded 16px, padding 2rem, transition transform 0.2s, border-color 0.2s
- `.feature-card:hover` — transform translateY(-4px), border-color var(--green)
- `.feature-card .icon` — font-size 2.5rem, margin-bottom 1rem
- `.feature-card h3` — font-size 1.125rem, font-weight 700, margin-bottom 0.5rem
- `.feature-card p` — font-size 0.9375rem, color var(--text-secondary), line-height 1.5
- Tablet: grid-template-columns repeat(2, 1fr)
- Mobile: grid-template-columns 1fr

**Step 3: Commit**

```bash
git add docs/index.html
git commit -m "feat: add feature cards grid section"
```

---

### Task 5: Email Showcase — Success Mockup

**Files:**
- Modify: `docs/index.html`

**Step 1: Add email showcase section and success mockup**

Section with:
- Title: "Know exactly what happened"
- Horizontal flex of 3 email mockup cards (this task = first one)

**Success mockup** — faithful HTML recreation of the actual Stagearr email:
- Outer card with soft green glow (`box-shadow: 0 0 40px rgba(34,197,94,0.15)`)
- Green "SUCCESS" badge (pill, centered)
- Movie metadata row: poster image + title + ratings
  - **Movie:** Wicked: For Good (2025)
  - **Poster:** `https://m.media-amazon.com/images/M/MV5BNzRhNTE4ZTYtNTM0Mi00MzU3LTk4MTktYWE3MzQ2NTU0MDNlXkEyXkFqcGc@._V1_SX300.jpg`
  - **Ratings:** ⭐ 6.7 · 🍅 66% · Ⓜ 58
  - **Genre:** Drama, Family, Fantasy · 137 min
  - **Label:** Movie · Radarr
  - **Link:** ↳ View on IMDb
- Details card (dark inner card):
  - Source: `Wicked.For.Good.2025.2160p.REMUX.DV.HDR.DDP.5.1.Atmos-GROUP`
  - Quality: **2160p Remux · Dolby Vision**
  - Files: **1 video (70.0 GB)**
  - Subtitles: **✓ English, Dutch**
  - Import: **Imported to library**
  - Duration: **3m 12s**
- Log file row (muted)
- Footer: "Stagearr v2.0.2"

**Step 2: Add email mockup base CSS**

- `.email-showcase` — display flex, gap 2rem, justify-content center
- `.email-mockup` — bg var(--bg-card), border 1px var(--border), rounded 16px, padding 2rem, max-width 380px, flex 1, transition transform 0.3s
- `.email-mockup:hover` — transform perspective(800px) rotateY(2deg) scale(1.02)
- `.email-badge` — display inline-flex, padding 0.375rem 1.25rem, rounded-full, font-weight 700, font-size 0.875rem, letter-spacing 0.05em
- `.email-badge.success` — bg var(--green), color white
- `.email-meta-row` — display flex, gap 1rem, align-items start
- `.email-poster` — width 80px, height auto, rounded 6px, object-fit cover
- `.email-details` — bg rgba(0,0,0,0.2), rounded 12px, padding 1.25rem
- `.email-detail-row` — display flex, border-bottom 1px rgba(border, 0.5), padding 0.5rem 0
- `.email-detail-label` — width 90px, color var(--text-muted), font-size 0.8125rem
- `.email-detail-value` — flex 1, font-size 0.875rem
- Rating badges: colored per source (IMDb yellow, RT red, MC green)

**Step 3: Commit**

```bash
git add docs/index.html
git commit -m "feat: add email showcase with success mockup"
```

---

### Task 6: Email Showcase — Warning and Failed Mockups

**Files:**
- Modify: `docs/index.html`

**Step 1: Add warning email mockup**

Same structure as success, but:
- **Badge:** amber "WARNING"
- **Show:** Dexter: New Blood (2021-2022)
- **Poster:** `https://m.media-amazon.com/images/M/MV5BZGY4YjY5MGItNzM2NS00Y2M1LWFkYTYtZjI0ZDk3NTE0NmE0XkEyXkFqcGc@._V1_SX300.jpg`
- **Ratings:** ⭐ 8.0
- **Genre:** Crime, Drama, Mystery · 1 season
- **Label:** TV · Sonarr
- Details: Source `Dexter.New.Blood.S01.1080p.WEB-DL.DDP5.1.H.264-NTb`, Quality 1080p WEB, Files 10 episodes (8.2 GB), Subtitles English (unavailable: Dutch), Import Imported to library, Duration 4m 12s
- **Notes section** (amber left border): "Dutch subtitles not found on OpenSubtitles"
- Card glow: amber (`box-shadow: 0 0 40px rgba(245,158,11,0.15)`)

**Step 2: Add failed email mockup**

Different structure (no poster/ratings):
- **Badge:** red "FAILED"
- **Title:** Cars (2006)
- **Subtitle:** Movie · Radarr
- **"What Happened" section** (red left border):
  - Source: `Cars.2006.2160p.UHD.BluRay.x265-CiNEPHiLES`
  - Phase: **Import**
  - Error: Folder is not accessible: path does not exist or permission denied
  - Path: `\\nas\media\staging\Cars.2006.2160p`
- **"What to Check" section** (dark card):
  - Is the network drive mounted?
  - Check Remote Path Mapping in Radarr
  - Does Radarr have read access to the folder?
- Card glow: red (`box-shadow: 0 0 40px rgba(239,68,68,0.15)`)

**Step 3: Add CSS for warning/failed variants**

- `.email-badge.warning` — bg var(--amber)
- `.email-badge.failed` — bg var(--red)
- `.email-notes` — border-left 3px solid var(--amber), padding-left 1rem, margin-top 1rem
- `.email-error-section` — border-left 3px solid var(--red), padding-left 1rem
- `.email-checklist li` — list-style "· ", color var(--text-secondary)

**Step 4: Add tagline below mockups**

"Metadata powered by OMDb — posters, ratings, genres, and IMDb links."

**Step 5: Add responsive styles for email section**

Mobile: stack mockups vertically, full width.

**Step 6: Commit**

```bash
git add docs/index.html
git commit -m "feat: add warning and failed email mockups"
```

---

### Task 7: Integration Logos Section

**Files:**
- Modify: `docs/index.html`

**Step 1: Add integration strip HTML**

Section with:
- Title: "Plugs into your stack"
- Horizontal flex row of 8 integration items
- Each item: inline SVG logo (or text fallback) + name below
- Items: qBittorrent, Radarr, Sonarr, Medusa, OpenSubtitles, OMDb, MKVToolNix, WinRAR
- Use well-known SVG logos where available; for less common tools use a styled text badge as fallback
- Each logo links to the tool's website

**Step 2: Add integration CSS**

- `.integrations` — display flex, flex-wrap wrap, justify-content center, gap 3rem, align-items center
- `.integration-item` — display flex, flex-direction column, align-items center, gap 0.5rem, opacity 0.5, filter grayscale(100%), transition 0.3s
- `.integration-item:hover` — opacity 1, filter grayscale(0%)
- `.integration-item img, .integration-item svg` — height 40px, width auto
- `.integration-item span` — font-size 0.75rem, color var(--text-muted)
- Mobile: reduce gap, 4-per-row grid

**Step 3: Commit**

```bash
git add docs/index.html
git commit -m "feat: add integration logos strip"
```

---

### Task 8: Footer + Final Polish

**Files:**
- Modify: `docs/index.html`

**Step 1: Add footer HTML**

- Horizontal layout: links left, version right
- Links: "Get Started" (wiki), "Documentation" (wiki), "GitHub" (repo)
- Right side: "Stagearr v2.0.2 · MIT License"
- Subtle top border (var(--border))

**Step 2: Add footer CSS**

- `.footer` — display flex, justify-content space-between, padding 2rem, border-top, max-width container
- `.footer a` — color var(--text-muted), hover: color var(--text-primary)
- Mobile: stack vertically, center align

**Step 3: Final polish pass**

- Verify all scroll animations fire correctly
- Check mobile layout at 375px width
- Check tablet at 768px
- Ensure no horizontal overflow
- Test that OMDb poster images load (external URLs)
- Add `<title>Stagearr — Automated Media Processing Pipeline</title>`
- Add favicon (use emoji or skip)

**Step 4: Commit**

```bash
git add docs/index.html
git commit -m "feat: add footer and final polish"
```

---

## Email Mockup Data Reference

**Success — Wicked: For Good (2025)**
- Poster: `https://m.media-amazon.com/images/M/MV5BNzRhNTE4ZTYtNTM0Mi00MzU3LTk4MTktYWE3MzQ2NTU0MDNlXkEyXkFqcGc@._V1_SX300.jpg`
- IMDb: 6.7 | RT: 66% | MC: 58
- Genre: Drama, Family, Fantasy · 137 min
- Quality: 2160p Remux · 70.0 GB

**Warning — Dexter: New Blood (2021)**
- Poster: `https://m.media-amazon.com/images/M/MV5BZGY4YjY5MGItNzM2NS00Y2M1LWFkYTYtZjI0ZDk3NTE0NmE0XkEyXkFqcGc@._V1_SX300.jpg`
- IMDb: 8.0
- Genre: Crime, Drama, Mystery · 1 season
- Quality: 1080p WEB · 10 episodes (8.2 GB)

**Failed — Cars (2006)**
- No poster displayed (failed = no metadata section)
- Quality: 2160p UHD BluRay
