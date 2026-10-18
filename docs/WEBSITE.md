# SI website

The landing page introduces SI and links to Releases, source, and installation instructions. It is a static site with no third-party runtime dependencies, remote fonts, analytics, API calls, or form submissions. The input animation uses fixed synthetic examples; it does not run or duplicate the input engine.

## Build and preview

Node.js 24+ and Python 3 are sufficient; no package installation is needed.

```sh
node scripts/build-website.mjs
python3 -m http.server 4173 --bind 127.0.0.1 --directory .build/website
```

Open <http://127.0.0.1:4173/> for English or <http://127.0.0.1:4173/zh/> for Simplified Chinese. Stop the server with Control-C. Output is confined to `.build/website/` and is ignored by Git.

## Content and localization

- `website/template.html` provides the shared accessible page structure.
- `website/locales/en.json` and `website/locales/zh-CN.json` contain the translated copy and metadata. Both must contain the same nonempty string keys; the build fails on missing translations or template keys.
- `website/assets/style.css` contains responsive styles and reduced-motion rules.
- `website/assets/demo.js` illustrates `shi` candidates, then separate commits for `nihao` and `world`. It has pause, resume, replay, and manual step controls. It starts paused for reduced-motion preferences and suspends animation while the document or demo is not visible.

English lives at `/` and Simplified Chinese at `/zh/`, relative to the hosting base path. Both pages are fully rendered at build time, include language metadata and alternate-language links, and remain readable without JavaScript. Language selection uses ordinary links and stays on the chosen URL. It does not modify SI's enabled input languages or store a browser preference. To add a locale, add its dictionary, route in `scripts/build-website.mjs`, and language navigation/alternate links in the template.

Use relative paths for local assets and language routes so the site works at the GitHub project path `/si/`, on a custom domain, or in a local preview. The SI favicon is an original text-only SVG; the decorative letterforms and window illustration use system fonts and CSS.

## Download status

As checked on October 18, 2026, the repository has no published release assets. The page therefore states that no packaged release is available, links to the Releases listing, and provides source-build and installation instructions. It never links to a nonexistent latest-release asset.

When a distributable is published, update `releaseStatus`, `releaseLabel`, and `releasesCta` in every locale, and the release button URL in `website/template.html`. Use a real asset URL, or `/releases/latest/download/<fixed-asset-name>` once a stable release has that exact asset. Do not describe an ad hoc development build as signed/notarized distribution.

## GitHub Pages

`.github/workflows/pages.yml` builds and validates the site on relevant pull requests. Pushes to `main` (or a manual run from `main`) additionally publish `.build/website/` with the official Pages actions. Pull requests cannot deploy. App source and repository documents are not included in the hosted artifact.

For the first deployment, enable **Settings → Pages → Build and deployment → Source → GitHub Actions** in the repository. After merging the website changes, the workflow publishes to `https://caterm-dev.github.io/si/`. Inspect the actual workflow result before treating the site as live.

For a custom domain, verify ownership in the GitHub organization, set the domain under the repository's **Settings → Pages → Custom domain**, then configure DNS and enable **Enforce HTTPS** when the certificate is ready. No domain is hard-coded in the site. With this Actions deployment, a `CNAME` file is not required; configure the domain in repository settings. Subdomain CNAME records point to `caterm-dev.github.io`, without a repository path.

References: [Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages), [custom domains](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site), [release links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).

## Verification

After building, check both routes at desktop and narrow mobile widths, including the `/si/` project-path deployment shape. Confirm that the language links, page anchors, GitHub links, download status, and layout work. Test pause/resume, replay, all three manual steps, keyboard access, reduced motion, and the no-JavaScript fallback. Check that animation shows the exact literal candidate, keeps both language labels visible, and depicts separate commits. Verify that scrolling away or changing tabs suspends the animation.

The website does not change input-method behavior or establish host-app compatibility. See [TESTING.md](TESTING.md) for the input method's separate verification requirements.

### Local verification record — October 18, 2026

- Generated both localized pages successfully with Node.js 24.21.0; checked JavaScript syntax, translation-key parity, output file scope, and all local asset/link/anchor targets.
- Inspected rendered English and Chinese pages in the Codex in-app browser at 1280px desktop and 390px/320px mobile widths. Confirmed language navigation, static content, and no horizontal document overflow. Also verified assets and both language routes under a nested hosting path.
- Exercised manual animation steps with pointer and keyboard input. An isolated execution harness using the actual animation script verified timed Chinese/English commits, pause/resume, replay, reduced-motion startup and preference changes, and hidden/offscreen suspension. This does not substitute for a manual screen-reader review; VoiceOver and a browser session with JavaScript disabled were not exercised. The generated HTML contains the complete content and static first scene, with playback controls hidden until script initialization.
- `./scripts/test.sh` passed 38 tests; `./scripts/build.sh` completed the Debug macOS build. Both required running outside the restricted sandbox for Swift compiler/macro processes. No input source was installed or changed.
- GitHub API checks found no published releases and no configured Pages site. The deployment workflow and domain settings remain unexercised until the website changes are published. No push or remote configuration change was made during verification.
