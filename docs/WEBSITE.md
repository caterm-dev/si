# SI website

The website introduces offline, on-device typing and links directly to its published R2 installer image, checksum, corresponding source, and installation instructions. It is a static site with no third-party runtime dependencies, remote fonts, analytics, API calls, or form submissions. The input animation uses fixed synthetic examples; it does not run or duplicate the input engine.

## Build and preview

Node.js 24+ and Python 3 are sufficient; no package installation is needed.

```sh
node scripts/build-website.mjs
python3 scripts/check-website.py
node scripts/check-website-animation.mjs
python3 -m http.server 4173 --bind 127.0.0.1 --directory .build/website
```

Open <http://127.0.0.1:4173/> for English or <http://127.0.0.1:4173/zh/> for Simplified Chinese. Each locale also has `privacy/` and `terms/` routes. The checker validates every local link, anchor, runtime asset, and alternate-language URL at both root and `/si/` hosting paths. The animation harness executes the actual script with synthetic DOM/timing fixtures to check complete manual scenes, exact commits, pause/replay, reduced-motion startup/changes, and hidden/offscreen suspension. Stop the server with Control-C. Output is confined to `.build/website/` and is ignored by Git.

## Content and localization

- `website/template.html` provides the landing-page structure; `website/legal.html` provides the shared policy layout with a section index, date, and contextual language navigation.
- `website/release.json` pins the public version, architecture, and asset metadata separately under `arm64` and `x86_64`, from each successfully published R2 channel. The build validates it and renders identical download URLs in both locales without browser-side fetching.
- `website/locales/en.json` and `website/locales/zh-CN.json` contain the translated copy and metadata. Both must contain the same nonempty string keys; the build fails on missing translations or template keys.
- `website/locales/legal.en.json` and `website/locales/legal.zh-CN.json` contain structured Privacy and Terms copy. The build validates nonempty fields, matching section IDs, and HTTPS reference links, and escapes all content before rendering. Privacy follows [PRIVACY.md](PRIVACY.md), including optional app data, retention/deletion, unencrypted local storage, inactive legacy data, and manual Sparkle requests. Terms preserve GPLv3 rights and preview limitations; do not introduce additional software-license restrictions. Review both policies and their displayed date when these facts change.
- `website/assets/style.css` contains responsive styles and reduced-motion rules.
- `website/assets/demo.js` illustrates ambiguous `shi` candidates, the bounded mixed candidate `woxiangyaodeploy` → `我想要deploy`, and exact `SI_build42` preservation with Return. Each is a separate composition. Candidate lists are selected illustrations, not engine results or promises of ordering. It has pause, resume, replay, and manual step controls. It starts paused for reduced-motion preferences and suspends animation while the document or demo is not visible.

English lives at `/` and Simplified Chinese at `/zh/`, relative to the hosting base path. All six pages are fully rendered at build time, include language metadata and alternate-language links, and remain readable without JavaScript. Language selection uses ordinary links and preserves the current page type, including Privacy and Terms. It does not modify SI's enabled input languages or store a browser preference. To add a locale, add its dictionary, route in `scripts/build-website.mjs`, and language navigation/alternate links in the template.

Use relative paths for local assets and language routes so the site works at the GitHub project path `/si/`, on a custom domain, or in a local preview. The SI favicon is an original text-only SVG; decorative letterforms, the illustrated input window, and the local-processing diagram use system fonts and CSS. Finite entrance/scroll transitions and demo motion respect reduced-motion preferences. Content stays visible if JavaScript is unavailable; playback controls are enabled only after initialization.

## Downloads

The page offers separate **Apple Silicon (arm64)** and **Intel (x86_64)** downloads. The hero button links to this platform choice; no Universal download is offered. Each option shows its own published version, architecture, decimal MB size, SHA-256 file link, and corresponding source archive. Versions can differ between architecture channels. Each download is a **DMG containing `Install SI.pkg`**. The current snapshot pins Apple Silicon 0.1.6 and Intel 0.1.8, verified anonymously on October 26, 2026.

The bilingual installation summary tells visitors to open the DMG, run `Install SI.pkg`, save their work before the Installer's final **Log Out** step, log back in, and add SI under **English** in Keyboard settings. Downloading/installing the published build does not require Xcode. Source-build instructions remain available separately. See [RELEASING.md](RELEASING.md#local-packaging) for the complete package behavior.

### Updating the pinned release

1. Finish publication with `scripts/release.sh`; do not run it just to build the website. Read the public channels `https://downloads.caterm.com/si/channels/mac/stable-arm64.json` and `https://downloads.caterm.com/si/channels/mac/stable-x86_64.json`. Use each channel’s actual version; publishing one architecture does not publish the other.
2. Anonymously download the DMG, checksum file, and source archive listed in the channel. Verify every file's byte size and SHA-256 against the manifest. Never copy a local release directory as proof of successful public publication.
3. Copy each channel’s `version`, `architecture`, and the three verified download/checksum/source `assets` into the matching `arm64` or `x86_64` entry in `website/release.json`. Do not copy signing identities, credentials, private configuration, or Sparkle update ZIPs. This is a reviewed static snapshot; the site does not automatically follow channel updates.
4. Keep the two explicit platform choices, architecture-specific accessible resource labels, and development-preview qualification in **both** locale dictionaries. The build requires valid metadata for both architectures; never substitute one platform’s asset or source archive for the other.
5. Run `node scripts/build-website.mjs`, inspect both locales and narrow screens, and commit/deploy the website changes through the existing Pages workflow. The build checks version/architecture, HTTPS asset URLs matching the release's version/architecture/filenames, positive byte sizes, and SHA-256 metadata before producing pages.

The website build uses checked-in metadata and performs no network requests. Downloads work through ordinary HTML links, including with JavaScript disabled, so browser CORS configuration is not needed. Generated Pages output contains six localized HTML files and presentation assets; release manifests, app source, and installer binaries are not copied into the Pages artifact. Source and checksum downloads are served directly from R2 alongside the DMG. The app's separate Sparkle update feed is managed by the [release tooling](RELEASING.md#in-app-updates), independently of the website snapshot.

## GitHub Pages

`.github/workflows/pages.yml` builds and validates the site on relevant pull requests. Pushes to `main` (or a manual run from `main`) additionally publish `.build/website/` with the official Pages actions. Pull requests cannot deploy. App source and repository documents are not included in the hosted artifact.

For the first deployment, enable **Settings → Pages → Build and deployment → Source → GitHub Actions** in the repository. After merging the website changes, the workflow publishes to `https://caterm-dev.github.io/si/`. Inspect the actual workflow result before treating the site as live.

For a custom domain, verify ownership in the GitHub organization, set the domain under the repository's **Settings → Pages → Custom domain**, then configure DNS and enable **Enforce HTTPS** when the certificate is ready. No domain is hard-coded in the site. With this Actions deployment, a `CNAME` file is not required; configure the domain in repository settings. Subdomain CNAME records point to `caterm-dev.github.io`, without a repository path.

References: [Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages), [custom domains](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site), [release links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).

## Verification

After building, check both routes at desktop and narrow mobile widths, including the `/si/` project-path deployment shape. Confirm that the language links, page anchors, GitHub links, download status, and layout work. Test pause/resume, replay, all three manual steps, keyboard access, reduced motion, and the no-JavaScript fallback. Check that animation shows the exact literal candidate, shows language identities for multilingual choices, and depicts independent compositions. Check the mixed spelling fits before its candidate appears, and the identifier scene shows Return rather than Space. Check Privacy/Terms links from both footers, policy section anchors, contextual language links, and the policy-to-home download links. Verify that scrolling away or changing tabs suspends the animation.

The website does not change input-method behavior or establish host-app compatibility. See [TESTING.md](TESTING.md) for the input method's separate verification requirements.

### Local verification record — October 18, 2026

- Generated both localized pages successfully with Node.js 24.21.0; checked JavaScript syntax, translation-key parity, output file scope, and all local asset/link/anchor targets.
- Inspected rendered English and Chinese pages in the Codex in-app browser at 1280px desktop and 390px/320px mobile widths. Confirmed language navigation, static content, and no horizontal document overflow. Also verified assets and both language routes under a nested hosting path.
- Exercised manual animation steps with pointer and keyboard input. An isolated execution harness using the actual animation script verified timed Chinese/English commits, pause/resume, replay, reduced-motion startup and preference changes, and hidden/offscreen suspension. This does not substitute for a manual screen-reader review; VoiceOver and a browser session with JavaScript disabled were not exercised. The generated HTML contains the complete content and static first scene, with playback controls hidden until script initialization.
- `./scripts/test.sh` passed 38 tests; `./scripts/build.sh` completed the Debug macOS build. Both required running outside the restricted sandbox for Swift compiler/macro processes. No input source was installed or changed.
- GitHub API checks found no published releases and no configured Pages site. The deployment workflow and domain settings remain unexercised until the website changes are published. No push or remote configuration change was made during verification.

### Download verification — October 20, 2026

- Read the live arm64 channel and independently downloaded its DMG, checksum, and corresponding source anonymously. All three byte sizes and SHA-256 hashes matched the channel metadata. Nothing was mounted, installed, or launched.
- Verified both generated locales contain two identical DMG links plus checksum/source links, correct version/architecture/size, and no unavailable-release message. Isolated build checks rejected missing source assets, mismatched architecture paths, insecure URLs, and malformed checksum metadata.
- Inspected the rendered download section on desktop and in English/Chinese at 320px width; neither mobile page overflowed horizontally. A browser click/download-event test timed out and could not confirm the browser's save completion; HTTP downloads and link destinations were verified separately. No claim is made about a completed browser download or installer execution.
- `./scripts/test.sh` passed 157 tests in 21 suites; `./scripts/build.sh` completed the Debug app build. Pages deployment was not triggered during this change.

### Platform download verification — October 26, 2026

- Read both public channels anonymously and verified all six linked DMG, checksum and source files against their channel byte sizes and SHA-256 hashes. Apple Silicon currently publishes 0.1.6; Intel publishes 0.1.8. No image was mounted or installed.
- Generated both locales and checked their architecture-specific download/resource URLs, local links, anchors, version/size text and absence of a Universal option. Isolated build checks rejected missing Intel metadata, mismatched architecture identity/path, missing source, insecure URLs, invalid sizes and malformed hashes.
- Inspected both desktop download sections and both locales in 320px sandboxed iframes with scripts disabled. Resource links have architecture-specific accessible names. A manual VoiceOver review and completed browser download remain unverified; file transfers were checked separately over HTTP.
- `./scripts/test.sh` passed 258 tests in 36 suites and `./scripts/build.sh` completed the Debug app build. Both ran outside the restricted sandbox for Swift/Xcode caches and compiler processes. No commit, deployment or installation was performed.

### Website refresh verification — October 26, 2026

- Added localized Privacy and Terms routes and refreshed the landing page around on-device, offline typing. Privacy copy distinguishes typing from manual updates and ordinary website/download connection metadata; it documents separately opted-in app memory and its limits. GPLv3 remains the software license.
- Built all six pages, checked JavaScript syntax, and ran `scripts/check-website.py` and `scripts/check-website-animation.mjs`. Link/anchor/alternate checks passed for root and `/si/` hosting paths; animation fixtures passed all three manual scenes, mixed/literal commits, pause/replay, reduced motion, and visibility suspension.
- Browser checks and their remaining limits are recorded after visual verification below.
- `./scripts/test.sh` passed 258 tests in 36 suites; `./scripts/build.sh` completed the Debug build. Both required execution outside the restricted sandbox for compiler processes/caches. These are shared-worktree checks and do not establish host-app compatibility. No input method was installed, and no commit or deployment was performed.
