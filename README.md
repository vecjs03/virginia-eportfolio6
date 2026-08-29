# Virginia Johnson Steeves — ePortfolio

MSc Medical Sciences (Schulich School of Medicine & Dentistry, Western University).
A single-page site with eight screens: Home, Community Rotation, Capstone,
Communicating Science, Academic Integrity, Science Policy, Seminar Series and
Laboratory Skills.

Deployed on Vercel — pushing to `main` publishes automatically.

## Run it locally

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tools/serve.ps1
```

Then open <http://localhost:8099>. Edits show up on reload (the server sends
`Cache-Control: no-store`, so there is nothing to hard-refresh).

## Layout

```
index.html          the whole site — all eight screens
assets/img/         photos, named after the slot they fill (home-portrait, lab-hero, …)
assets/fonts/       Instrument Serif, Karla, Space Mono (woff2 subsets)
assets/js/          dc-runtime, image-slot, react, react-dom — vendored, no CDN calls
assets/favicon.svg  the VJS monogram
tools/serve.ps1     the local preview server
tools/unpack-bundle.ps1   one-shot converter, kept for provenance (see below)
```

## Editing

Each screen is one `<main data-screen-label="…">` block in `index.html`. Find the
label, edit the copy or markup inside it.

The page runs the Claude Design runtime (`assets/js/dc-runtime.js`), so a few
non-standard tags appear in the markup:

| Tag / attribute | What it does |
| --- | --- |
| `<sc-if value="{{ x }}">` | renders its contents only when `x` is truthy |
| `<sc-for list="{{ xs }}" as="x">` | repeats its contents once per item |
| `sc-camel-on-click="{{ fn }}"` | binds a click to a method on the component |
| `<image-slot id="…" src="…">` | a fillable image placeholder |
| `{{ expr }}` | interpolates component state |

State, page routing and the content arrays (lab sessions, capstone steps,
seminars, the slide deck) live in the `<script type="text/x-dc">` block near the
bottom of `index.html`. Editing the text of a seminar or a lab session means
editing those arrays, not the markup.

To swap a photo, drop the new file into `assets/img/` and point the matching
`<image-slot src="…">` at it.

## Provenance

This started as a Claude Design canvas export: one 8.4 MB `index.html.html` whose
real markup sat inside a JSON-escaped string, with all 48 images, fonts and
scripts base64'd beside it. `tools/unpack-bundle.ps1` converted it losslessly
into the plain files above.

The original bundle is preserved in git history and can be restored with:

```bash
git show f8f36a8:index.html.html > index.html.html
```
