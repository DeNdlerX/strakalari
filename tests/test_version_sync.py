"""The version is written in three places; they must never drift apart.

CI stamps the release version from the tag, but a local build, the
in-app update check and ``pip install .`` all read the committed values.
"""

import re
import tomllib
from pathlib import Path

import strakalari

ROOT = Path(__file__).resolve().parent.parent


def _pep440(semver: str) -> str:
    """``0.1.0-beta.3`` -> ``0.1.0b3`` (the spelling pyproject.toml needs).

    Same mapping as the "Stamp version into app" step in build.yml, which
    rewrites all three files from the release tag before the tests run.
    """
    m = re.fullmatch(r"(\d+(?:\.\d+)*)(?:-(alpha|beta|rc)\.?(\d+))?(?:-(.+))?", semver)
    assert m, f"unexpected version spelling: {semver!r}"
    base, kind, num, other = m.groups()
    pep = base + ({"alpha": "a", "beta": "b", "rc": "rc"}[kind] + num if kind else "")
    if other:
        pep += "+" + re.sub(r"[^0-9A-Za-z]+", ".", other)
    return pep


def test_pyproject_matches_package():
    data = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    assert data["project"]["version"] == _pep440(strakalari.__version__)


def test_installer_default_matches_package():
    text = (ROOT / "installer.iss").read_text(encoding="utf-8")
    m = re.search(r'#define MyAppVersion "([^"]+)"', text)
    assert m and m.group(1) == strakalari.__version__


def test_pep440_mapping():
    assert _pep440("1.2.3") == "1.2.3"
    assert _pep440("0.1.0-beta.3") == "0.1.0b3"
    assert _pep440("2.0.0-rc.1") == "2.0.0rc1"
    assert _pep440("1.0.0-nightly-2") == "1.0.0+nightly.2"
