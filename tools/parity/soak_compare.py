"""Soak parity compare: canonical JSON diff modulo timestamps.

Usage::

    python tools/parity/soak_compare.py py.json dart.json

Loads the two files produced by ``tools/parity/soak_refresh.py`` (Python)
and ``packages/strakalari_core/bin/refresh_dryrun.dart`` (Dart), drops
every ``ts`` timestamp recursively (audit entries are written at run
time, so they can never match exactly), re-canonicalizes, and reports
the first difference — or ``IDENTICAL (modulo ts)`` with exit code 0.

Exit code is 1 on any parity difference.
"""

from __future__ import annotations

import json
import sys


def strip_ts(value):
    if isinstance(value, dict):
        return {k: strip_ts(v) for k, v in value.items()
                if k not in ("ts", "last_updated")}
    if isinstance(value, list):
        return [strip_ts(v) for v in value]
    return value


def canonical(value):
    if isinstance(value, dict):
        return {str(k): canonical(value[k]) for k in sorted(value, key=str)}
    if isinstance(value, list):
        return [canonical(v) for v in value]
    return value


def first_diff(a, b, path=""):
    if type(a) is not type(b):
        return f"{path or '$'}: type {type(a).__name__} != {type(b).__name__}"
    if isinstance(a, dict):
        for k in a:
            if k not in b:
                return f"{path or '$'}.{k}: only in first file"
        for k in b:
            if k not in a:
                return f"{path or '$'}.{k}: only in second file"
        for k in a:
            d = first_diff(a[k], b[k], f"{path or '$'}.{k}")
            if d:
                return d
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return (f"{path or '$'}: length {len(a)} != {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff(x, y, f"{path}[{i}]")
            if d:
                return d
        return None
    if a != b:
        return f"{path or '$'}: {a!r} != {b!r}"
    return None


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[0])
        print(f"usage: {sys.argv[0]} py.json dart.json")
        return 2
    with open(sys.argv[1], encoding="utf-8") as f:
        left = canonical(strip_ts(json.load(f)))
    with open(sys.argv[2], encoding="utf-8") as f:
        right = canonical(strip_ts(json.load(f)))
    diff = first_diff(left, right)
    if diff is None:
        print("IDENTICAL (modulo ts)")
        return 0
    print(f"PARITY DIFFERENCE: {diff}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
