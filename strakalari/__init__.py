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
from .core.extractors.strava import clean_text
from .core.extractors.bakalari import extract_grades

__version__ = "0.1.0"

__all__ = [
    "Strakalari",
    "encrypt",
    "decrypt",
    "parse_date",
    "extract_lesson_num",
    "_resolve_path",
    "clean_text",
    "extract_grades",
]
