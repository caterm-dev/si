# DMG packaging and R2 publication

SI is a development preview. These scripts build distributables; they do not establish host compatibility or provide automatic updates. Complete the relevant [manual integration checks](TESTING.md) before a public release.

## Local packaging

Requires macOS 14+, Xcode 26+ with Swift 6.2+, and Python 3.9+. No extra Python packages or DMG utilities are needed.

```sh
./scripts/package-dmg.sh --dry-run
./scripts/package-dmg.sh
./scripts/package-dmg.sh --arch arm64
./scripts/package-dmg.sh --arch x86_64
```

The default is a Universal Release build containing Apple Silicon and Intel slices. Packaging uses the existing Xcode SI target with signing disabled, then signs a staged copy. Without `--sign`, the copy receives an ad hoc signature and is only a local preview. Build data lives under `.build/dmg-<arch>/`; final DMG and `.dmg.sha256` files live under `.build/releases/<version>/<arch>/`. `--output-dir` overrides the artifact directory. Existing final files are never silently replaced.

The DMG contains `Install SI.pkg`, `Install SI.txt`, and `LICENSE.txt`. Open the package to use macOS Installer, which installs `SI.app` in `~/Library/Input Methods` for the current user only. The final **Log Out** button uses Installer's `RequireLogout` conclusion action. Save work first, log out through the button, then log back in to finish input-method registration; the package does not require a full Mac restart. After logging in, add SI under English in Keyboard settings and select it. It never enables or selects an input source automatically.

The preinstall script refuses root/system-wide installation, symbolic-link destinations, a running SI, process-query failures, and foreign bundles. Existing current/legacy SI apps are copied to `~/Library/Application Support/SI/Backups/Installer.*/SI.app` before replacement; a failed backup stops installation. Native Installer atomically replaces the bundle; preserve backups for manual recovery if installation fails. Bundle relocation is disabled. Native strict-ID matching is disabled to permit the legacy ID migration; preinstall instead checks the two explicit SI IDs. This package is separate from the source-based `scripts/install.sh` workflow and does not compile Swift on the recipient's Mac.

Packaging itself never installs or launches SI or logs out. No logout/restart command runs in package scripts; the user initiates logout through macOS Installer, with the system's ordinary application save/cancel handling. Cancelling logout leaves installed files in place; log out later to finish registration. There is no `/Applications` shortcut or input-method executable launched from the DMG.

## Signing and notarization

Use Developer ID Application and Developer ID Installer certificates from the same team, already installed in Keychain, plus an existing `notarytool` Keychain profile. Configure these outside the repository; do not put passwords, private keys, certificates, or personal signing settings into tracked files.

```sh
export SI_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID1234)'
export SI_INSTALLER_IDENTITY='Developer ID Installer: Your Name (TEAMID1234)'
export SI_NOTARY_PROFILE='si-notary'
./scripts/package-dmg.sh --dry-run
./scripts/package-dmg.sh
```

`--sign IDENTITY`, `--installer-sign IDENTITY` and `--notarize-profile PROFILE` override the environment. Notarization requires both identities. The script signs nested dylibs before the app with hardened runtime and a timestamp, signs the product package with the Installer identity and verifies its signature, then verifies app and DMG signatures. It submits the DMG to Apple, requires an `Accepted` response, staples and validates its ticket, then verifies the image. Checksums are computed after stapling. A failed notarization never exposes a final DMG; use the submission ID with `xcrun notarytool log` for Apple diagnostics. This step sends the packaged application to Apple's notarization service. An unsigned local package is for preview only.

## Publish to Cloudflare R2

The defaults share Caterm's public R2 account/bucket (`pub`), `caterm-r2` AWS profile, and `https://downloads.caterm.com` domain. All SI objects live under `si/`; Caterm release and channel paths are untouched. Install a current AWS CLI v2 supporting conditional `put-object` requests. The profile needs Object Read & Write access to the public bucket; no bucket administration is required. If needed, configure credentials interactively with `aws configure --profile caterm-r2`, using region `auto`. Never paste credentials into release command arguments.

With signing variables configured:

```sh
./scripts/release.sh --dry-run
./scripts/release.sh
```

Publication requires both Developer ID signing and notarization, plus a clean committed checkout. It records the exact Git revision and checks that the checkout/version have not changed after packaging. The script does not bump versions, commit, tag, push, deploy the website, or configure Cloudflare. Set `MARKETING_VERSION` consistently in both Xcode configurations and update `CURRENT_PROJECT_VERSION` before committing a new release. Versioned R2 files cannot change bytes; publish changed builds under a new version.

For the initial Universal version, the object layout is:

```text
si/releases/0.1.0/mac/universal/SI-0.1.0-universal.dmg
si/releases/0.1.0/mac/universal/SI-0.1.0-universal.dmg.sha256
si/releases/0.1.0/mac/universal/SI-0.1.0-source.tar.gz
si/releases/0.1.0/mac/universal/manifest.json
si/channels/mac/stable-universal.json
```

The source archive contains the exact committed tree, including GPLv3 and vocabulary provenance/licenses. It accompanies the binary to provide corresponding source independently of GitHub availability. The manifest lists version, revision, architecture, notarization status, signing identity, and each asset's public URL, SHA-256 and byte size. Architecture-specific releases have independent paths/channels; pass `--arch arm64` or `--arch x86_64` to build and publish one.

The script checks R2 access before building, uploads only the explicit artifacts, and downloads each through the anonymous public URL to verify SHA-256. Existing identical objects can be reused; differing bytes are rejected. Only after all downloads pass does it update the channel JSON using an ETag condition (or create-only condition). A newer channel or conflicting same-version manifest is rejected. Another publisher winning the conditional write causes a failure rather than an overwrite. A channel verification failure after the write may mean the channel already advanced; inspect it and retry the same release.

Completed releases are cached locally with `manifest.json`. An identical retry validates cached metadata, every file's size/hash/URL, the DMG signature and stapled ticket before reusing it. Keep the completed directory for retries. A failure before the manifest is completed can leave a local final DMG/checksum; use another output directory or remove only that unpublished output after reviewing it. Do not rebuild an already published version with different bytes.

One local lock covers packaging and publication. It does not lock Git edits or releases on other machines; remote conditional writes provide the final overwrite guard.

Configuration overrides (flags or environment):

| Flag | Environment | Default |
| --- | --- | --- |
| `--account-id` | `SI_R2_ACCOUNT_ID` | Caterm's public Cloudflare account |
| `--bucket` | `SI_R2_BUCKET` | `pub` |
| `--prefix` | `SI_R2_PREFIX` | `si` |
| `--public-url` | `SI_R2_PUBLIC_URL` | `https://downloads.caterm.com` |
| `--profile` | `SI_R2_PROFILE` | `caterm-r2` |

Use `--profile ''` with standard AWS environment/default credentials in CI. The public URL must already serve the bucket anonymously, without an Access login or WAF challenge; the script does not change bucket/domain policies. `--dry-run` reads local metadata and prints a plan without creating files, contacting Apple/R2, signing, or building. It cannot verify credentials, certificates, notarization profiles, public access, or actual upload success.

After a real successful publication, update both website locales and the download URL as described in [WEBSITE.md](WEBSITE.md). A channel JSON is metadata for release tooling, not a built-in SI updater. Keep the website's unavailable-release status until an actual artifact has been published and verified.

References: [Cloudflare AWS CLI configuration](https://developers.cloudflare.com/r2/examples/aws/aws-cli/), [R2 S3 compatibility](https://developers.cloudflare.com/r2/api/s3/api/), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Apple Installer distribution domains and conclusion actions](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html).
