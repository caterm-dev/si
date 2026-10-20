"""Package SI for macOS; optionally publish verified downloads to Cloudflare R2."""
import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
IMMUTABLE_CACHE = "public, max-age=31536000, immutable"
CHANNEL_CACHE = "no-cache, max-age=0, must-revalidate"


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["arm64", "x86_64", "universal"], default="universal")
    parser.add_argument("--sign", default=os.environ.get("SI_SIGN_IDENTITY"), metavar="IDENTITY",
                        help="Application identity; publication detects a unique valid code-signing identity")
    parser.add_argument("--installer-sign", default=os.environ.get("SI_INSTALLER_IDENTITY"), metavar="IDENTITY",
                        help="Developer ID Installer identity for the package inside the DMG")
    parser.add_argument("--notarize-profile", default=os.environ.get("SI_NOTARY_PROFILE"), metavar="PROFILE",
                        help="notarytool Keychain profile (publication default: caterm-notary)")
    parser.add_argument("--output-dir", type=Path, help="default: .build/releases/<version>/<arch>")
    parser.add_argument("--dry-run", action="store_true", help="print plan without writes or network requests")
    parser.add_argument("--publish", action="store_true", help="upload artifacts and promote the R2 channel")
    # Non-secret defaults match Caterm's public bucket, under a separate SI prefix.
    parser.add_argument("--account-id", default=os.environ.get("SI_R2_ACCOUNT_ID", "8e5cfe29add1b0bcab4a4ba85161f859"))
    parser.add_argument("--bucket", default=os.environ.get("SI_R2_BUCKET", "pub"))
    parser.add_argument("--prefix", default=os.environ.get("SI_R2_PREFIX", "si"))
    parser.add_argument("--public-url", default=os.environ.get("SI_R2_PUBLIC_URL", "https://downloads.caterm.com"))
    parser.add_argument("--profile", default=os.environ.get("SI_R2_PROFILE", "caterm-r2"),
                        help="AWS profile; empty string uses AWS environment/default credentials")
    args = parser.parse_args(argv)
    if args.sign and not re.fullmatch(r"Developer ID Application: .+ \([A-Z0-9]{10}\)", args.sign):
        parser.error("--sign requires Developer ID Application: Name (TEAMID)")
    if args.installer_sign and not re.fullmatch(r"Developer ID Installer: .+ \([A-Z0-9]{10}\)", args.installer_sign):
        parser.error("--installer-sign requires Developer ID Installer: Name (TEAMID)")
    if args.sign and args.installer_sign and args.installer_sign[-12:] != args.sign[-12:]:
        parser.error("--installer-sign requires an Application identity from the same team")
    if not re.fullmatch(r"[0-9a-f]{32}", args.account_id):
        parser.error("--account-id must be a Cloudflare account ID")
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", args.bucket):
        parser.error("invalid R2 bucket name")
    if not re.fullmatch(r"[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*", args.prefix):
        parser.error("--prefix must be a nonempty object path without dots or leading/trailing slashes")
    args.public_url = args.public_url.rstrip("/")
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+(?::[0-9]+)?(?:/[A-Za-z0-9_-]+)*", args.public_url):
        parser.error("--public-url must be an HTTPS URL without credentials, query or fragment")
    return args


def keychain_identities(kind, policy):
    try:
        result = subprocess.run(["security", "find-identity", "-v", "-p", policy], check=True,
                                capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("Cannot inspect Keychain signing identities; supply --sign and --installer-sign "
                         "or SI_SIGN_IDENTITY and SI_INSTALLER_IDENTITY") from error
    pattern = r'"(Developer ID ' + kind + r': [^"\n]+ \([A-Z0-9]{10}\))"'
    return sorted(set(re.findall(pattern, result.stdout)))


def resolve_signing(args):
    if not (args.publish or args.sign or args.installer_sign or args.notarize_profile):
        return  # Local packaging remains an ad hoc preview unless signing was requested.
    if not args.sign:
        # A basic-policy identity can fail code-signing validation. Select the app first,
        # rather than switching teams just because another team has an Installer identity.
        applications = keychain_identities("Application", "codesigning")
        if args.installer_sign:
            applications = [name for name in applications if name[-12:] == args.installer_sign[-12:]]
        if not applications:
            raise ValueError("No valid Developer ID Application identity found under the code-signing policy. "
                             "Install a current certificate and its private key")
        if len(applications) != 1:
            raise ValueError("Multiple valid Application identities found; choose --sign:\n  " +
                             "\n  ".join(applications))
        args.sign = applications[0]
    if not args.installer_sign:
        # Installer identities use the basic policy, not the code-signing policy.
        installers = [name for name in keychain_identities("Installer", "basic") if name[-12:] == args.sign[-12:]]
        if not installers:
            raise ValueError(f"No valid Developer ID Installer identity for signing team {args.sign[-11:-1]}. "
                             f"Selected Application identity: {args.sign}. Install a Developer ID Installer "
                             "certificate and its private key for this team; another team's certificate cannot be used")
        if len(installers) != 1:
            raise ValueError("Multiple matching Installer identities found; choose --installer-sign:\n  " +
                             "\n  ".join(installers))
        args.installer_sign = installers[0]
    if args.publish and not args.notarize_profile:
        args.notarize_profile = "caterm-notary"
    print(f"Application signing: {args.sign}", flush=True)
    print(f"Installer signing: {args.installer_sign}", flush=True)
    if args.notarize_profile:
        print(f"Notarization profile: {args.notarize_profile} (must belong to signing team {args.sign[-11:-1]})", flush=True)


def run(command, dry=False, capture=False):
    command = list(map(str, command))
    print("+ " + shlex.join(command), flush=True)
    if dry:
        return ""
    result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else ""


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def version_number(version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Release version must be X.Y.Z")
    return tuple(map(int, version.split(".")))


def project_version(root):
    project = (root / "mac/SI.xcodeproj/project.pbxproj").read_text()
    versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", project))
    if len(versions) != 1:
        raise ValueError("Xcode configurations must have the same MARKETING_VERSION")
    version = versions.pop()
    version_number(version)
    return version


def validate_checkout(root, version, revision):
    if git(root, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Commit changes before publishing; the checkout must be clean")
    if git(root, "rev-parse", "HEAD") != revision or project_version(root) != version:
        raise ValueError("Checkout changed during packaging; publication stopped")


def digest(path, algorithm="sha256"):
    hasher = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher


def install_readme(root, contents):
    # Installation is handled by macOS Installer, including the final Log Out button.
    (contents / "Install SI.txt").write_text(
        "SI development preview — macOS 14 or later\n\n"
        "1. Save your work, select another input source, and finish any composition.\n"
        "2. Open Install SI.pkg and follow the macOS Installer. It installs SI\n"
        "   in ~/Library/Input Methods and backs up an existing SI app. If SI is\n"
        "   running, log out and back in with another source selected, then retry.\n"
        "3. At the end, click Log Out, then log back in to finish registration.\n"
        "   This ends your login session; it does not restart your Mac.\n"
        "4. System Settings > Keyboard > Text Input > Edit > + > English > SI.\n"
        "5. Choose SI in the input menu; open SI Settings to choose languages.\n\n"
        "The installer does not enable or select an input source automatically.\n"
        "This preview still requires host-app compatibility verification.\n"
        "To uninstall, select another source, remove SI in Keyboard settings, move\n"
        "~/Library/Input Methods/SI.app to Trash, then log out and back in.\n\n"
        "Source, vocabulary notices and local install/backup tooling:\n"
        "https://github.com/caterm-dev/si\n"
        "Published releases include corresponding source as SI-<version>-source.tar.gz.\n"
        "SI is licensed under GPLv3; see LICENSE.txt.\n", encoding="utf-8")
    shutil.copyfile(root / "LICENSE", contents / "LICENSE.txt")


def build_installer(args, root, work, contents, version):
    installer = root / "scripts/installer"
    resources = work / "installer-resources"
    scripts = work / "installer-scripts"
    if not args.dry_run:
        resources.mkdir()
        scripts.mkdir()
        for name in ("Welcome.txt", "Conclusion.txt"):
            shutil.copyfile(installer / name, resources / name)
        shutil.copyfile(root / "LICENSE", resources / "LICENSE.txt")
        shutil.copy2(installer / "preinstall", scripts / "preinstall")
    run(["pkgbuild", "--root", work / "payload", "--identifier", "com.caterm.si.installer",
         "--version", version, "--install-location", "/Library/Input Methods",
         "--component-plist", installer / "components.plist", "--scripts", scripts,
         work / "SI-component.pkg"], args.dry_run)
    command = ["productbuild", "--distribution", installer / "Distribution.xml",
               "--package-path", work, "--resources", resources]
    if args.installer_sign:
        command += ["--sign", args.installer_sign, "--timestamp"]
    run([*command, contents / "Install SI.pkg"], args.dry_run)
    if args.installer_sign:
        run(["pkgutil", "--check-signature", contents / "Install SI.pkg"], args.dry_run)


def package(args, root, version, output):
    name = f"SI-{version}-{args.arch}.dmg"
    destination = output / name
    if destination.exists() or destination.with_suffix(".dmg.sha256").exists():
        raise ValueError(f"Output already exists: {destination}; use another --output-dir")
    derived = root / ".build" / f"dmg-{args.arch}"
    architectures = ["arm64", "x86_64"] if args.arch == "universal" else [args.arch]
    build = ["xcodebuild", "-project", root / "mac/SI.xcodeproj", "-scheme", "SI",
             "-configuration", "Release", "-destination", "generic/platform=macOS",
             "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=NO",
             "ARCHS=" + " ".join(architectures), "build"]
    run(build, args.dry_run)
    if not args.dry_run:
        output.mkdir(parents=True, exist_ok=True)
    staging = (contextlib.nullcontext(str(output / ".dry-run")) if args.dry_run else
               tempfile.TemporaryDirectory(prefix=".si-dmg-", dir=output))
    with staging as directory:
        work = Path(directory)
        contents = work / "contents"
        app = work / "payload/SI.app"
        image = work / name
        if not args.dry_run:
            contents.mkdir()
            app.parent.mkdir()
            install_readme(root, contents)
        run(["ditto", derived / "Build/Products/Release/SI.app", app], args.dry_run)
        if not args.dry_run:
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if (info.get("CFBundleIdentifier") != "com.caterm.inputmethod.si" or
                    info.get("CFBundleShortVersionString") != version):
                raise ValueError("Built app identity/version does not match SI release")
        actual = run(["lipo", "-archs", app / "Contents/MacOS/SI"], args.dry_run, capture=True)
        if not args.dry_run and set(actual.split()) != set(architectures):
            raise ValueError(f"Built app architectures differ: {actual.strip()}")
        signing = ["codesign", "--force", "--sign", args.sign or "-"]
        if args.sign:
            signing += ["--options", "runtime", "--timestamp"]
        if not args.dry_run:
            for library in sorted((app / "Contents/MacOS").glob("*.dylib")):
                run([*signing, library])
        run([*signing, app], args.dry_run)
        run(["codesign", "--verify", "--deep", "--strict", app], args.dry_run)
        build_installer(args, root, work, contents, version)
        run(["hdiutil", "create", "-volname", "SI", "-srcfolder", contents,
             "-format", "UDZO", image], args.dry_run)
        if args.sign:
            run(["codesign", "--sign", args.sign, "--timestamp", image], args.dry_run)
            run(["codesign", "--verify", "--strict", image], args.dry_run)
        if args.notarize_profile:
            response = run(["xcrun", "notarytool", "submit", image, "--keychain-profile",
                            args.notarize_profile, "--wait", "--output-format", "json"], args.dry_run, capture=True)
            if not args.dry_run:
                submission = json.loads(response)
                if submission.get("status") != "Accepted":
                    raise ValueError(f"Apple notarization failed: {response.strip()}; use notarytool log with the submission ID")
            run(["xcrun", "stapler", "staple", image], args.dry_run)
            run(["xcrun", "stapler", "validate", image], args.dry_run)
        run(["hdiutil", "verify", image], args.dry_run)
        if not args.dry_run:
            checksum = digest(image).hexdigest()
            image.rename(destination)
            destination.with_suffix(".dmg.sha256").write_text(f"{checksum}  {name}\n")
    print(f"DMG: {destination}", flush=True)
    if not args.notarize_profile:
        print("Local preview only; not notarized for public distribution.", flush=True)
    return destination


class Storage:
    def __init__(self, args):
        self.bucket = args.bucket
        self.prefix = args.prefix
        self.command = ["aws", "--endpoint-url", f"https://{args.account_id}.r2.cloudflarestorage.com",
                        "--region", "auto", "--output", "json"]
        if args.profile:
            self.command += ["--profile", args.profile]
        self.env = dict(os.environ, AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off",
                        AWS_REQUEST_CHECKSUM_CALCULATION="when_required",
                        AWS_RESPONSE_CHECKSUM_VALIDATION="when_required")

    def request(self, operation, *args, missing=False):
        result = subprocess.run([*self.command, "s3api", operation, "--bucket", self.bucket, *map(str, args)],
                                env=self.env, capture_output=True, text=True)
        if result.returncode:
            if missing and "(NoSuchKey)" in result.stderr:
                return None
            raise ValueError(f"R2 {operation} failed: {result.stderr.strip()}")
        return json.loads(result.stdout or "{}")

    def preflight(self):
        skeleton = subprocess.check_output([*self.command, "s3api", "put-object", "--generate-cli-skeleton", "input"],
                                           env=self.env, text=True)
        if not {"IfMatch", "IfNoneMatch"} <= json.loads(skeleton).keys():
            raise ValueError("Update AWS CLI v2 for conditional put-object support")
        self.request("list-objects-v2", "--prefix", self.prefix + "/", "--max-keys", "1")

    def get(self, key, destination):
        return self.request("get-object", "--key", key, destination, missing=True)

    def put(self, key, path, content_type, cache, condition):
        self.request("put-object", "--key", key, "--body", path, "--content-type", content_type,
                     "--cache-control", cache, "--content-md5", base64.b64encode(digest(path, "md5").digest()).decode(),
                     "--metadata", json.dumps({"sha256": digest(path).hexdigest()}), *condition)

    def immutable(self, key, path, content_type):
        with tempfile.TemporaryDirectory(prefix="si-r2-") as directory:
            existing = Path(directory) / "object"
            if self.get(key, existing) is not None:
                if digest(existing).digest() != digest(path).digest():
                    raise ValueError(f"Published object differs: {key}; use a new version")
                return
        self.put(key, path, content_type, IMMUTABLE_CACHE, ("--if-none-match", "*"))


def verify_public(args, key, expected):
    request = urllib.request.Request(f"{args.public_url}/{key}", headers={
        "User-Agent": "SI-Release (+https://github.com/caterm-dev/si)", "Cache-Control": "no-cache"})
    hasher = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=60) as response:
        if not response.url.startswith(args.public_url + "/"):
            raise ValueError(f"Unexpected public download redirect: {key}")
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            hasher.update(chunk)
    if hasher.hexdigest() != expected:
        raise ValueError(f"Public download checksum differs: {key}; channel not confirmed")


def metadata(args, version, revision):
    return {"version": version, "revision": revision, "platform": "macos", "architecture": args.arch,
            "notarized": True, "signing_identity": args.sign,
            "installer_signing_identity": args.installer_sign, "installer": "pkg-require-logout"}


def prepare_release(args, root, version, revision, output):
    manifest = output / "manifest.json"
    prefix = f"{args.prefix}/releases/{version}/mac/{args.arch}"
    if manifest.exists():
        content = json.loads(manifest.read_text())
        expected = metadata(args, version, revision)
        if {key: content.get(key) for key in expected} != expected:
            raise ValueError("Cached release metadata differs; use a new output directory")
        print(f"Reusing cached release: {manifest}", flush=True)
    else:
        image = package(args, root, version, output)
        source = output / f"SI-{version}-source.tar.gz"
        run(["git", "-C", root, "archive", "--format=tar.gz", f"--prefix=si-{version}/",
             "-o", source, revision])
        validate_checkout(root, version, revision)
        content = metadata(args, version, revision)
        content["assets"] = {path.name: {"sha256": digest(path).hexdigest(), "size": path.stat().st_size,
                                         "url": f"{args.public_url}/{prefix}/{path.name}"}
                             for path in (image, image.with_suffix(".dmg.sha256"), source)}
        manifest.write_text(json.dumps(content, indent=2) + "\n")
    names = {f"SI-{version}-{args.arch}.dmg", f"SI-{version}-{args.arch}.dmg.sha256", f"SI-{version}-source.tar.gz"}
    if set(content.get("assets", {})) != names:
        raise ValueError("Cached release has unexpected assets")
    for name, item in content["assets"].items():
        path = output / name
        if (path.is_symlink() or not path.is_file() or digest(path).hexdigest() != item["sha256"] or
                path.stat().st_size != item["size"] or item["url"] != f"{args.public_url}/{prefix}/{name}"):
            raise ValueError(f"Cached release artifact differs: {name}")
    image = output / f"SI-{version}-{args.arch}.dmg"
    run(["codesign", "--verify", "--strict", image])
    run(["xcrun", "stapler", "validate", image])
    return manifest


def validate_channel(content, current):
    if current is None:
        return
    if current.get("platform") != "macos" or current.get("architecture") != content["architecture"]:
        raise ValueError("Unexpected existing channel metadata")
    if version_number(current["version"]) > version_number(content["version"]):
        raise ValueError("Refusing to downgrade the published channel")
    if version_number(current["version"]) == version_number(content["version"]) and current != content:
        raise ValueError("This version already has different published content; use a new version")


def publish(args, manifest, storage):
    content = json.loads(manifest.read_text())
    prefix = f"{args.prefix}/releases/{content['version']}/mac/{args.arch}"
    channel = f"{args.prefix}/channels/mac/stable-{args.arch}.json"
    with tempfile.TemporaryDirectory(prefix="si-channel-") as directory:
        current_path = Path(directory) / "current.json"

        def read_channel():
            result = storage.get(channel, current_path)
            current = json.loads(current_path.read_text()) if result else None
            validate_channel(content, current)
            return current, result

        read_channel()
        for name in [*content["assets"], manifest.name]:
            path = manifest.parent / name
            content_type = ("application/x-apple-diskimage" if name.endswith(".dmg") else
                            "application/gzip" if name.endswith(".gz") else
                            "application/json" if name.endswith(".json") else "text/plain; charset=utf-8")
            storage.immutable(f"{prefix}/{name}", path, content_type)
            verify_public(args, f"{prefix}/{name}", digest(path).hexdigest())
        # Compare-and-swap after all anonymous downloads pass; concurrent releases cannot clobber it.
        current, result = read_channel()
        if current != content:
            condition = ("--if-match", result["ETag"]) if result else ("--if-none-match", "*")
            storage.put(channel, manifest, "application/json", CHANNEL_CACHE, condition)
        verify_public(args, channel, digest(manifest).hexdigest())
    print(f"Published: {args.public_url}/{channel}", flush=True)
    image_name = f"SI-{content['version']}-{args.arch}.dmg"
    print(f"Download: {content['assets'][image_name]['url']}", flush=True)


def main(argv=None):
    args = arguments(argv)
    resolve_signing(args)
    version = project_version(ROOT)
    revision = git(ROOT, "rev-parse", "HEAD")
    output = (args.output_dir or ROOT / ".build/releases" / version / args.arch).resolve()
    if args.dry_run:
        if args.publish and (output / "manifest.json").exists():
            print(f"Validate cached release: {output / 'manifest.json'}")
        else:
            package(args, ROOT, version, output)
        if args.publish:
            print(f"Require clean checkout at {revision}; reuse verified cached release if present.")
            print(f"Archive corresponding source; upload DMG, SHA-256, source and manifest.json to "
                  f"R2 {args.bucket}/{args.prefix}/releases/{version}/mac/{args.arch}/")
            print(f"Verify public downloads, then conditionally promote "
                  f"{args.public_url}/{args.prefix}/channels/mac/stable-{args.arch}.json")
        return
    if sys.platform != "darwin":
        raise ValueError("DMG packaging requires macOS; use --dry-run to inspect the plan")
    for tool in ["xcodebuild", "xcrun", "lipo", "codesign", "ditto", "hdiutil", "pkgbuild", "productbuild", "pkgutil"] + (["aws"] if args.publish else []):
        if not shutil.which(tool):
            raise ValueError(f"Required tool not found: {tool}")
    lock_root = ROOT / ".build"
    lock_root.mkdir(exist_ok=True)
    with (lock_root / "release.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another SI packaging/release process is running") from error
        if args.publish:
            validate_checkout(ROOT, version, revision)
            storage = Storage(args)
            storage.preflight()
            manifest = prepare_release(args, ROOT, version, revision, output)
            validate_checkout(ROOT, version, revision)
            publish(args, manifest, storage)
        else:
            package(args, ROOT, version, output)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, urllib.error.URLError) as error:
        raise SystemExit(f"SI release failed: {error}") from error
    except KeyboardInterrupt:
        raise SystemExit("SI release interrupted; rerun to reuse a completed cached release")
