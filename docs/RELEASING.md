# DMG packaging and R2 publication

SI is a development preview. These scripts build distributables and the user-initiated Sparkle update channel; they do not establish host compatibility. Complete the relevant [manual integration checks](TESTING.md) before a public release.

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

`./scripts/release.sh --arch arm64` reads public identity names using `security find-identity -v -p codesigning` to select a unique valid Developer ID Application identity. It then uses `security find-identity -v -p basic` to find an Installer identity belonging to that same team. Basic-policy validity alone does not establish suitability for signing an app. Expired/invalid Application identities excluded by macOS's code-signing policy cannot redirect automatic selection. A missing Installer identity produces a specific error naming the selected Application/team; the script never chooses another team's complete pair instead. Multiple valid Application identities require an explicit `--sign`, even if only one team has an Installer identity. Explicit `--installer-sign` constrains Application discovery to that team. Missing/ambiguous identities stop before building and never fall back to unsigned publication. Explicit flags override environment variables, which override automatic discovery. When both identities are explicit, discovery is skipped. No certificate/private-key data is read or copied by discovery, and no personal identity/team is hard-coded. The default notarization profile remains `caterm-notary`.

The selected certificate names and notarization profile are printed before building. The profile must belong to the selected team; automatic certificate selection does not verify that association. If your matching pair belongs to a different team than Caterm's notarization credentials, supply the correct profile using `--notarize-profile` or `SI_NOTARY_PROFILE`. Plain local `package-dmg.sh` remains an ad hoc preview unless signing/notarization is explicitly requested. For explicit configuration:

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

With a unique valid Application identity, its matching Installer identity, and Caterm's existing profiles (or explicit configuration above):

```sh
./scripts/release.sh --dry-run
./scripts/release.sh
```

Publication requires both Developer ID signing and notarization, plus a clean committed checkout. After certificate selection and R2 preflight pass, a new release automatically increments the patch component of `MARKETING_VERSION` (`0.1.0` → `0.1.1`, `0.0.9` → `0.0.10`) and the integer `CURRENT_PROJECT_VERSION` by one in both Debug and Release configurations. Major/minor components are retained. The script commits only `mac/SI.xcodeproj/project.pbxproj` with the message `Bump version to X.Y.Z`, then builds/archives that exact committed revision. Git author identity and any required commit signing must already work locally. A failed version commit restores the script's edit only if no intervening edit/commit changed it. The script does not tag, push, deploy the website, or configure Cloudflare.

`--dry-run` prints the proposed version/build increment and commit without editing files or Git history. Plain `package-dmg.sh` never increments or commits. Use `./scripts/release.sh --no-bump` to publish the current version without any increment, including when publishing another architecture of the same release:

```sh
./scripts/release.sh --arch arm64            # New patch version
./scripts/release.sh --arch x86_64 --no-bump  # Same version for Intel
```

Pending version/revision metadata is stored under `.build/release-pending-<arch>.json` before building and removed only after successful publication/public verification. If a build, notarization or upload fails, rerunning the same architecture at the same clean commit automatically resumes that version instead of incrementing again. The marker also recovers an interruption between committing the version and recording its new SHA. Once publication succeeds, the next normal invocation increments again. A changed committed checkout starts a new patch; pending state from a different revision does not silently reuse old artifacts. Keep `.build/` for automatic retries. If the marker is lost, use `--no-bump` explicitly to retry the current version; never rebuild different bytes under an already published version. An explicit output directory must be fresh for a new release or contain only the matching cached release.

Both Xcode configurations must have matching marketing versions and matching integer build numbers. Dirty tracked/staged/untracked source prevents automatic commits; commit your source changes first. Missing signing identities or a failed R2 preflight do not increment the version. A later failure retains the committed version for retry. Versioned R2 files cannot change bytes; publish changed builds under a new version.

For version `0.1.1`, the Universal object layout is:

```text
si/releases/0.1.1/mac/universal/SI-0.1.1-universal.dmg
si/releases/0.1.1/mac/universal/SI-0.1.1-universal.dmg.sha256
si/releases/0.1.1/mac/universal/SI-0.1.1-source.tar.gz
si/releases/0.1.1/mac/universal/manifest.json
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

Use `--profile ''` with standard AWS environment/default credentials in CI. The public URL must already serve the bucket anonymously, without an Access login or WAF challenge; the script does not change bucket/domain policies. `--dry-run` reads local metadata and public Keychain identity names when automatic discovery is needed, then prints a plan without creating files, contacting Apple/R2, signing, or building. It cannot verify private-key signing access, notarization-profile/team association, service credentials, public access, or actual upload success. Supply both identities explicitly for an offline dry-run without Keychain access.

After a real successful publication, update both website locales and the download URL as described in [WEBSITE.md](WEBSITE.md). The channel JSON is metadata for release tooling; the separate XML feed serves the built-in updater. Keep the website's unavailable-release status until an actual artifact has been published and verified.

## In-app updates

SI uses [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/tree/2.10.0), pinned in the Xcode project and `Package.resolved`, with the standard [programmatic updater UI](https://sparkle-project.org/documentation/programmatic-setup/). It is an MIT-licensed runtime dependency with permissively licensed components compatible with GPLv3 redistribution. The unchanged upstream notice is included in `mac/SI/Resources/Sparkle-LICENSE.txt` and the app resources; the framework retains its bundled notices. First app builds resolve the official package/binary through Xcode. No third-party update source code is generated. This dependency and use of Caterm's scheme were explicitly requested for this feature.

**Check for Updates…** is available in Settings and the input menu for the installed Release app. Automatic checks, automatic installation and profile submission are disabled. Debug and uninstalled copies do not start Sparkle. Save work and finish composition before installing; Sparkle terminates/replaces/restarts the existing app, using normal termination to flush pending personal-data writes. If macOS does not resume typing, log out and back in. Native upgrade/registration behavior remains a required release check. Existing versions without Sparkle need one manual installation of an updater-enabled release.

The public EdDSA key matches Caterm's existing key; signing uses Keychain account `com.caterm.agent`. No private key is exported, generated or stored in this repository. Before version mutation, publication downloads the official Sparkle 2.10.0 tools to `.build/Sparkle-2.10.0` and verifies distribution SHA-256 `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`, then requires the Keychain public key to match `SUPublicEDKey`. Tool/key failures stop the release. Local packaging and dry runs do not access this key or fetch signing tools. Release command output includes only public-key metadata/signatures, never private-key material.

Publication signs Sparkle's XPC services, Autoupdate, Updater app and framework before the SI bundle. It separately submits an app-only ZIP to Apple, requires Accepted, staples/validates the app, then creates the final `SI-<version>-<arch>-update.zip`. The pkg-based first-install DMG still receives its existing signing/notarization. The final ZIP gets an EdDSA signature, byte size and SHA-256 in the manifest, with the integer build counter in `build` and signature in `update_signature`. Cached retries verify the ZIP signature again in addition to all existing file checks.

For a Universal release, additional public paths are:

```text
si/releases/0.1.1/mac/universal/SI-0.1.1-universal-update.zip
si/channels/mac/stable-universal.xml
```

The app-only ZIP is intentional: Sparkle's [package updates](https://sparkle-project.org/documentation/package-updates/) use a privileged installer, which does not match SI's home-only pkg contract. Sparkle instead replaces the running app at its current installed location. This path does not execute the initial installer's backup/logout flow; retain the previous DMG and existing Installer backups for recovery. Finish pending composition before installing. No code forces logout, changes enabled input sources, or bypasses the source installer's running-process guard.

The XML appcast points only to the app ZIP, uses `CURRENT_PROJECT_VERSION` as `sparkle:version`, displays `MARKETING_VERSION`, requires macOS 14+, and includes the EdDSA signature. All immutable artifacts, including source, must pass public hash verification before conditional JSON promotion; XML promotion happens last, also using create-only/ETag conditions and anonymous verification. Existing newer feeds or conflicting same-version/build feeds stop publication. If JSON succeeds and XML fails, retry the same cached version (`--no-bump` if local pending state was lost); a partial promotion never authorizes overwriting a newer feed.

Universal builds use `stable-universal.xml` on both CPUs; architecture-specific builds use their own `stable-arm64.xml` or `stable-x86_64.xml`. `SI_UPDATE_ARCH` and `SI_UPDATE_FEED_URL` are set during packaging and validated in the built Info.plist, including public URL/prefix overrides. Changing hosting later requires an explicit feed migration. A release without the final XML feed is not a working in-app update channel.

References: [Cloudflare AWS CLI configuration](https://developers.cloudflare.com/r2/examples/aws/aws-cli/), [R2 S3 compatibility](https://developers.cloudflare.com/r2/api/s3/api/), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Apple Installer distribution domains and conclusion actions](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html).
