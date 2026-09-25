"""
HTML extractors for Bakalari and Strava portals.
"""
from .bakalari import extract_absence_percentages
from .strava import clean_text, extract_food_data, extract_ordered_food

__all__ = [
    "extract_absence_percentages",
    "clean_text",
    "extract_food_data",
    "extract_ordered_food",
]
