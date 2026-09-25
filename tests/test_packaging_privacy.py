"""No personal file may ever be bundled into a build or the installer.

The frozen app and the Inno installer are built from a developer's
checkout, which usually holds a real config.json, secret.key, cache and
scraped pages next to the sources.
"""
import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PERSONAL = re.compile(
    r"(^|[\\/])(config\.json|secret\.key|data_cache\.json|update_cache\.json|log\.txt"
    r"|strava_blacklist\.json|already_excused_lessons\.json|automation_history\.jsonl"
    r"|htmls)([\\/]|$)",
    re.IGNORECASE,
)


def _installer_sources():
    text = (ROOT / "installer.iss").read_text(encoding="utf-8-sig")
    section = text.split("[Files]", 1)[1].split("\n[", 1)[0]
    return re.findall(r'^Source:\s*"([^"]+)"', section, flags=re.MULTILINE)


def _spec_datas():
    tree = ast.parse((ROOT / "strakalari.spec").read_text(encoding="utf-8"))
    found = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Tuple) and len(node.elts) == 2 and all(
                isinstance(e, ast.Constant) and isinstance(e.value, str) for e in node.elts):
            found.append(node.elts[0].value)
    return found


def test_installer_ships_no_personal_files():
    sources = _installer_sources()
    assert sources, "installer [Files] section not found"
    assert [s for s in sources if PERSONAL.search(s)] == []


def test_installer_seeds_history_only_from_the_empty_template():
    text = (ROOT / "installer.iss").read_text(encoding="utf-8-sig")
    assert 'Source: "already_excused_lessons.example.json"' in text
    assert (ROOT / "already_excused_lessons.example.json").read_text().strip() == "[]"


def test_spec_bundles_no_personal_files():
    datas = _spec_datas()
    assert "config.example.json" in datas
    assert [d for d in datas if PERSONAL.search(d)] == []


def test_personal_files_are_gitignored():
    ignored = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
    for name in ("config.json", "secret.key", "data_cache.json", "htmls/",
                 "automation_history.jsonl", "already_excused_lessons.json"):
        assert name in ignored, name
