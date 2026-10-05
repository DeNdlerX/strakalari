"""Pack the frozen Strakalari.exe as an (unsigned) MSIX for the Store.

Usage (CI fills everything from the release version + secrets)::

    python tools/make_msix.py --exe dist/Strakalari.exe \\
        --out Strakalari-0.2.0.msix --version 0.2.0 \\
        --identity-name "YourCompany.Strakalari" \\
        --publisher "CN=..." --publisher-display "Your Company"

The package is intentionally UNSIGNED: the Microsoft Store signs Store
submissions itself, so no code-signing certificate is needed. Standard
library only (runs on the CI runner with plain python).

``--layout DIR`` also keeps the unpacked package in DIR: with Developer
Mode on, ``Add-AppxPackage -Register DIR\\AppxManifest.xml`` installs it
with a real package identity, unsigned (see docs/STORE.md).
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

REQUIRED_ASSETS = ("StoreLogo.png", "Square150x150Logo.png", "Square44x44Logo.png")
OPTIONAL_ASSETS = ("Wide310x150Logo.png", "Square310x310Logo.png")


def msix_version(version: str) -> str:
    """'0.2.0' -> '0.2.0.0'. Pre-releases are refused (Store submissions
    are stable releases only; the CI publish job is skipped for them)."""
    core = str(version or "").strip().lstrip("vV")
    if not re.fullmatch(r"\d+(\.\d+){1,2}", core):
        raise SystemExit(
            f"MSIX version must be numeric X.Y[.Z] without a suffix, got {version!r} "
            "(Store submissions are stable releases only)."
        )
    parts = core.split(".")
    while len(parts) < 4:
        parts.append("0")
    return ".".join(parts)


def find_makeappx(explicit: str | None) -> str:
    if explicit:
        if not os.path.isfile(explicit):
            raise SystemExit(f"MakeAppx not found at {explicit!r}")
        return explicit
    found = shutil.which("makeappx.exe") or shutil.which("makeappx")
    if found:
        return found
    kits = sorted(
        glob.glob(
            r"C:\Program Files (x86)\Windows Kits\10\bin\*\x64\MakeAppx.exe"
        )
    )
    if kits:
        return kits[-1]
    raise SystemExit(
        "MakeAppx.exe not found: install the Windows SDK "
        "(https://developer.microsoft.com/windows/downloads/windows-sdk/) "
        "or pass --makeappx explicitly."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, help="Frozen Strakalari.exe")
    parser.add_argument("--out", required=True, help="Output .msix path")
    parser.add_argument("--version", required=True, help="Release version, e.g. 0.2.0")
    parser.add_argument("--identity-name", required=True)
    parser.add_argument("--publisher", required=True, help="e.g. CN=12345678-...")
    parser.add_argument("--publisher-display", required=True)
    parser.add_argument("--arch", default="x64")
    parser.add_argument("--manifest", default=os.path.join(REPO_ROOT, "msix", "AppxManifest.xml"))
    parser.add_argument("--assets", default=os.path.join(REPO_ROOT, "assets", "msix"))
    parser.add_argument("--makeappx", default=None)
    parser.add_argument("--layout", default=None,
                        help="Keep the unpacked package here (emptied first)")
    args = parser.parse_args()

    if not os.path.isfile(args.exe):
        raise SystemExit(f"exe not found: {args.exe}")
    if not os.path.isfile(args.manifest):
        raise SystemExit(f"manifest template not found: {args.manifest}")
    version4 = msix_version(args.version)
    makeappx = find_makeappx(args.makeappx)

    with open(args.manifest, "r", encoding="utf-8-sig") as handle:
        template = handle.read()
    for token in ("@IDENTITY_NAME@", "@PUBLISHER@", "@VERSION@", "@ARCH@",
                  "@PUBLISHER_DISPLAY@"):
        if token not in template:
            raise SystemExit(f"manifest template lost its {token} token")
    manifest = (
        template.replace("@IDENTITY_NAME@", args.identity_name)
        .replace("@PUBLISHER@", args.publisher)
        .replace("@VERSION@", version4)
        .replace("@ARCH@", args.arch)
        .replace("@PUBLISHER_DISPLAY@", args.publisher_display)
    )

    if args.layout:
        stage = os.path.abspath(args.layout)
        shutil.rmtree(stage, ignore_errors=True)
        os.makedirs(stage)
    else:
        stage = tempfile.mkdtemp(prefix="strakalari-msix-")
    try:
        shutil.copy2(args.exe, os.path.join(stage, "Strakalari.exe"))
        with open(os.path.join(stage, "AppxManifest.xml"), "w", encoding="utf-8") as handle:
            handle.write(manifest)
        assets_dir = os.path.join(stage, "Assets")
        os.makedirs(assets_dir)
        for name in REQUIRED_ASSETS:
            src = os.path.join(args.assets, name)
            if not os.path.isfile(src):
                raise SystemExit(f"required logo missing: {src}")
            shutil.copy2(src, os.path.join(assets_dir, name))
        for name in OPTIONAL_ASSETS:
            src = os.path.join(args.assets, name)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(assets_dir, name))

        out = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        cmd = [makeappx, "pack", "/d", stage, "/p", out, "/o"]
        print("+ " + " ".join(cmd))
        proc = subprocess.run(cmd, capture_output=True, text=True)
        sys.stdout.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        if proc.returncode != 0:
            raise SystemExit(f"MakeAppx failed with exit code {proc.returncode}")
    finally:
        if not args.layout:
            shutil.rmtree(stage, ignore_errors=True)

    size_mb = os.path.getsize(out) / (1024 * 1024)
    print(f"wrote {out} ({size_mb:.1f} MB, unsigned — the Store signs it)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
