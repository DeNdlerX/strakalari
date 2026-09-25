"""
Strakalari - Automated school absence excusing and food ordering.
"""

from .core.automation import Strakalari
from .core.helpers import (
    _resolve_path,
    encrypt,
    decrypt,
    parse_date,
    extract_lesson_num,
)
from .core.extractors.strava import extract_food_data, extract_ordered_food, clean_text
from .core.extractors.bakalari import extract_absence_percentages, extract_grades, extract_sent_excuses

__version__ = "0.1.0-beta.3"

# Heavy/browser-dependent names are resolved lazily (PEP 562) so that
# `import strakalari` never requires Playwright to be installed.
_LAZY_ATTRS = {
    "ensure_browser": (".core.browser", "ensure_browser"),
    "is_browser_installed": (".core.browser", "is_browser_installed"),
}


def __getattr__(name: str):
    target = _LAZY_ATTRS.get(name)
    if target is not None:
        import importlib
        module_name, attr_name = target
        module = importlib.import_module(module_name, __name__)
        return getattr(module, attr_name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


__all__ = [
    "Strakalari",
    "ensure_browser",
    "is_browser_installed",
    "encrypt",
    "decrypt",
    "parse_date",
    "extract_lesson_num",
    "_resolve_path",
    "extract_food_data",
    "extract_ordered_food",
    "clean_text",
    "extract_absence_percentages",
    "extract_grades",
    "extract_sent_excuses",
]
