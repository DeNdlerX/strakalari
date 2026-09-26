"""Every relative import in the package points at a real module and name.

Function-level imports only run when their handler fires, so a wrong
``..`` depth (a module moved into a subpackage) passes lint and every
build test, then crashes on the user's click. Settings → Rules → Auto
mode did exactly that (``from ..safety`` inside ``views/settings``).
"""

import ast
import importlib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "strakalari"


def _relative_imports():
    for path in sorted(PACKAGE.rglob("*.py")):
        rel = path.relative_to(ROOT).with_suffix("")
        parts = list(rel.parts)
        package = parts[:-1] if parts[-1] != "__init__" else parts[:-1]
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if isinstance(node, ast.ImportFrom) and node.level:
                base = package[:len(package) - (node.level - 1)]
                target = ".".join(base + ([node.module] if node.module else []))
                names = [a.name for a in node.names if a.name != "*"]
                yield pytest.param(target, names, id=f"{rel.as_posix()}:{node.lineno}")


@pytest.mark.parametrize("target,names", list(_relative_imports()))
def test_relative_import_resolves(target, names):
    module = importlib.import_module(target)
    for name in names:
        if hasattr(module, name):
            continue
        # ``from . import submodule``
        importlib.import_module(f"{target}.{name}")
