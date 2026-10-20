#!/usr/bin/env python3
"""Stage and ad-hoc sign the locally built macOS GUI preview."""
import argparse
import hashlib
import json
import platform
import plistlib
import re
import shutil
import subprocess
from pathlib import Path
from verification import release_evidence,feature_batches,code_hash,dependency_notices,local_preview_evidence

ROOT = Path(__file__).resolve().parents[1]


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Run on macOS after tools/build.py --native")
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-preview", action="store_true", help="Current local tests only; no release acceptance claim")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist", help="Directory for the app and archives")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    evidence = local_preview_evidence() if args.local_preview else release_evidence("native")
    batches = feature_batches()
    binary = ROOT / "zig-out/native/bin/letty"
    loads = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    minimum = re.search(r"\bminos\s+(\S+)", loads)
    if not minimum:
        raise SystemExit("Cannot determine the binary's macOS minimum version")
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    bundle = output / "Letty.app"
    if bundle.exists():
        shutil.rmtree(bundle)
    contents = bundle / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(ROOT / "assets/icons/Letty.icns", resources / "Letty.icns")
    executable = macos / "Letty"
    shutil.copy2(binary, executable)
    executable.chmod(0o755)
    info = {
        "CFBundleName": "Letty",
        "CFBundleDisplayName": "Letty",
        "CFBundleExecutable": "Letty",
        "CFBundleIdentifier": "dev.letty.terminal",
        "CFBundleIconFile": "Letty.icns",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": minimum.group(1),
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
        "NSSupportsAutomaticGraphicsSwitching": True,
    }
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    shutil.copy2(ROOT / "docs/macos-preview.md", resources / "README.md")
    shutil.copy2(ROOT / "config/config.example", resources / "config.example")
    shutil.copy2(ROOT / "docs/configuration.md", resources / "configuration.md")
    shutil.copytree(ROOT / "docs", resources / "docs")
    shutil.copytree(ROOT / "config", resources / "config")
    shutil.copytree(ROOT / "assets/shell-integration", resources / "shell-integration")
    shutil.copy2(ROOT / "deps.lock.json", resources / "deps.lock.json")
    licenses = resources / "licenses"
    licenses.mkdir()
    for vendor in ["nanoui", "ghostty"]:
        for notice in (ROOT / "vendor" / vendor).glob("LICENSE*"):
            if notice.is_file():
                shutil.copy2(notice, licenses / (vendor + "-" + notice.name))
    for notice, relative in dependency_notices():
        target = licenses / relative
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(notice, target)
    metadata = {
        "version": "0.1.0-dev",
        "vt_backend": evidence["vt_backend"],
        "feature_batches": batches,
        "target_acceptance": "CentOS/VDI pending",
        "verification": evidence,
        "zig": "0.17.0",
        "architecture": arch,
        "minimum_macos": minimum.group(1),
        "build_host": platform.platform(),
        "text_backend": "CoreText; color glyphs converted to grayscale ink",
        "font": "Maple Mono Normal NL NF CN",
        "theme": "Paper (Otty)",
        "signing": "ad-hoc local preview",
        "notarized": False,
    }
    if not args.local_preview:
        (resources / "feature-acceptance.json").write_text(json.dumps(evidence["feature_acceptance"], indent=2) + "\n")
        shutil.copy2(ROOT / ".cache/verification/native-release-gate.json", resources / "native-release-gate.json")
        metadata["native_validation"] = "developer gate passed; CentOS/VDI/IME pending"
    if args.local_preview:
        metadata["native_validation"] = "local developer preview only; full release gate not applied"
    (resources / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
    subprocess.run(["plutil", "-lint", str(contents / "Info.plist")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", info["CFBundleIdentifier"], str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", "--verbose=2", str(bundle)], check=True)
    archive = output / f"Letty-macos-{arch}-preview.zip"
    archive.unlink(missing_ok=True)
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(bundle), str(archive)], check=True)
    archive.with_suffix(".zip.sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n")
    label = "local-preview" if args.local_preview else "native-zig"
    versioned = archive.with_name(f"Letty-macos-{arch}-{label}-{code_hash()[:12]}.zip")
    shutil.copy2(archive, versioned)
    versioned.with_suffix(".zip.sha256").write_text(hashlib.sha256(versioned.read_bytes()).hexdigest() + "  " + versioned.name + "\n")
    print("Versioned archive:", versioned)
    print("App:", bundle)
    print("Archive:", archive)


if __name__ == "__main__":
    main()
