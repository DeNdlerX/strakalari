import re
import html


def _is_ordered_label(text: str) -> bool:
    """True when a Strava ``aria-label`` marks the meal as ordered.

    Ordered buttons read ``Objednáno - …`` (past locked days prefix it
    with ``Změna pole zakázána - ``); unordered ones read ``Neobjednáno``.
    ASCII substrings on purpose (no diacritics, no encoding risk).
    """
    lowered = str(text or "").strip().lower()
    return "objedn" in lowered and "neobjedn" not in lowered


def _is_day_header_id(meal_id: str) -> bool:
    """True for the ``&-1&`` day-header control (not a real meal).

    Its label is always ``Objednáno - den undefined`` regardless of the
    day's orders, so it must never count as ordered detection.
    """
    return "&-1&" in str(meal_id or "")


def clean_text(text: str) -> str:
    """Removes HTML tags, newlines, tabs, and unescapes HTML entities."""
    if not text:
        return ""

    # 1. Replace line break and block tags with a space to prevent words merging
    text = re.sub(r'<(?:br\s*/?|/div|/p|/tr|/td)[^>]*>', ' ', text, flags=re.IGNORECASE)

    # 2. Remove any remaining HTML tags (e.g., <span>, <path d="...">, etc.)
    text = re.sub(r'<[^>]+>', '', text)

    # 3. Unescape HTML entities (converts &amp; to &, &lt; to <, etc.)
    text = html.unescape(text)

    # 4. Normalize whitespace (replace newlines/tabs/multiple spaces with a single space)
    text = re.sub(r'\s+', ' ', text)

    # 5. Strip leading/trailing spaces
    return text.strip()


def extract_food_data(html_string: str) -> dict:
    """Extracts available meals grouped by date from Strava HTML."""
    result = {}
    if not html_string:
        return result

    # Pattern to find the starting <div id="DD.MM.YYYY"> tag, supporting single or double digits (e.g. 1.9.2026 or 01.09.2026).
    div_start_pattern = re.compile(
        r'<div[^>]*?id\s*=\s*["\'](\d{1,2}\.\s*\d{1,2}\.\s*\d{4})["\'][^>]*>',
        re.IGNORECASE
    )

    # Pattern to find the label, supporting both &amp; and literal & in attribute.
    label_pattern = re.compile(
        r'<label[^>]*?for\s*=\s*["\'](table[-+]?\d+(?:&amp;|&)[-+]?\d+(?:&amp;|&)[-+]?\d+)["\'][^>]*>(.*?)</label>',
        re.IGNORECASE | re.DOTALL
    )

    div_matches = list(div_start_pattern.finditer(html_string))

    for i, div_match in enumerate(div_matches):
        raw_date_id = div_match.group(1)
        # Collapse spaces around dots ("4. 9. 2026" -> "4.9.2026") so date
        # keys match the zero-padded lookups used by the views.
        date_id = re.sub(r"\s*\.\s*", ".", clean_text(raw_date_id))

        # Define the chunk of HTML belonging to this specific div
        start_pos = div_match.end()
        end_pos = div_matches[i + 1].start() if i + 1 < len(div_matches) else len(html_string)
        div_chunk = html_string[start_pos:end_pos]

        if date_id not in result:
            result[date_id] = {}

        # Search for all labels inside this specific chunk
        for label_match in label_pattern.finditer(div_chunk):
            raw_table_id = label_match.group(1)
            raw_inner_data = label_match.group(2)

            # Clean both the dictionary key and the inner data value
            clean_table_id = clean_text(raw_table_id)
            inner_data = clean_text(raw_inner_data)

            result[date_id][clean_table_id] = inner_data

    return result


def extract_ordered_food(html_string: str) -> dict:
    """
    Extracts the currently ordered meal identifier for each date from the HTML.
    Looks for checked input elements or checked labels.
    Returns a dict mapping date (e.g. '04.09.2026' or '4.9.2026') -> ordered table_id (e.g. 'table123&1&0').
    """
    result = {}
    if not html_string:
        return result

    # Pattern to find the starting <div id="DD.MM.YYYY"> tag, supporting single or double digits.
    div_start_pattern = re.compile(
        r'<div[^>]*?id\s*=\s*["\'](\d{1,2}\.\s*\d{1,2}\.\s*\d{4})["\'][^>]*>',
        re.IGNORECASE
    )

    # Matches <input ...> tags
    input_tag_pattern = re.compile(
        r'<input\b[^>]*>',
        re.IGNORECASE
    )
    id_pattern = re.compile(
        r'\bid\s*=\s*["\'](table[-+]?\d+(?:&amp;|&)[-+]?\d+(?:&amp;|&)[-+]?\d+)["\']',
        re.IGNORECASE
    )
    # Matches checked attribute while preventing false positives on data-checked="false" or checked="false"
    checked_pattern = re.compile(
        r'(?<![-_a-zA-Z0-9])checked(?:\s*=\s*["\']?(?:checked|true|1)["\']?|\s|/|>|$)',
        re.IGNORECASE
    )

    # Also support labels with aria-checked="true" or checked / selected / active class
    label_checked_pattern = re.compile(
        r'<label\b[^>]*?(?:aria-checked=["\']true["\']|\bclass=["\'][^"\']*\b(?:checked|selected|active)\b)[^>]*?\bfor=["\'](table[-+]?\d+(?:&amp;|&)[-+]?\d+(?:&amp;|&)[-+]?\d+)["\']',
        re.IGNORECASE
    )
    label_checked_pattern2 = re.compile(
        r'<label\b[^>]*?\bfor=["\'](table[-+]?\d+(?:&amp;|&)[-+]?\d+(?:&amp;|&)[-+]?\d+)["\'][^>]*?(?:aria-checked=["\']true["\']|\bclass=["\'][^"\']*\b(?:checked|selected|active)\b)',
        re.IGNORECASE
    )
    # Also support any element (span, button, div, a) with table id and active/checked class
    element_checked_pattern = re.compile(
        r'<[a-z0-9]+\b[^>]*?(?:\bclass=["\'][^"\']*\b(?:checked|selected|active)\b|aria-checked=["\']true["\'])[^>]*?\bid=["\'](table[-+]?\d+(?:&amp;|&)[-+]?\d+(?:&amp;|&)[-+]?\d+)["\']',
        re.IGNORECASE
    )
    element_checked_pattern2 = re.compile(
        r'<[a-z0-9]+\b[^>]*?\bid=["\'](table[-+]?\d+(?:&amp;|&)[-+]?\d+(?:&amp;|&)[-+]?\d+)["\'][^>]*?(?:\bclass=["\'][^"\']*\b(?:checked|selected|active)\b|aria-checked=["\']true["\'])',
        re.IGNORECASE
    )

    # Modern Strava frontend: per-meal buttons carry the state explicitly
    # in aria-label ("Objednáno - …" vs "Neobjednáno - …"; locked past days
    # prefix it with "Změna pole zakázána - "). Strongest signal — checked
    # before the legacy input/label patterns. Attribute order varies.
    # IDs allow the same [-+]? parts as every other pattern (incl. &-1&).
    button_ordered_pattern = re.compile(
        r'''<button[^>]*?aria-label=["']([^"']*)["'][^>]*?id=["'](table[-+]?\d+&(?:amp;)?[-+]?\d+&(?:amp;)?[-+]?\d+)["']'''
        r'''|<button[^>]*?id=["'](table[-+]?\d+&(?:amp;)?[-+]?\d+&(?:amp;)?[-+]?\d+)["'][^>]*?aria-label=["']([^"']*)["']''',
        re.IGNORECASE,
    )

    div_matches = list(div_start_pattern.finditer(html_string))
    for i, div_match in enumerate(div_matches):
        date_id = re.sub(r"\s*\.\s*", ".", clean_text(div_match.group(1)))
        start_pos = div_match.end()
        end_pos = div_matches[i + 1].start() if i + 1 < len(div_matches) else len(html_string)
        div_chunk = html_string[start_pos:end_pos]

        # Explicit button aria-labels first (modern frontend, strongest).
        for button_match in button_ordered_pattern.finditer(div_chunk):
            if button_match.group(2):
                label_text, raw_id = button_match.group(1), button_match.group(2)
            else:
                label_text, raw_id = button_match.group(4), button_match.group(3)
            clean_id = clean_text(raw_id)
            if _is_day_header_id(clean_id):
                continue
            if _is_ordered_label(html.unescape(label_text)):
                result[date_id] = clean_id
                break

        if date_id in result:
            continue
        # First check inputs with checked property/attribute
        seen: list[str] = []
        for input_match in input_tag_pattern.finditer(div_chunk):
            input_html = input_match.group(0)
            if checked_pattern.search(input_html):
                id_m = id_pattern.search(input_html)
                if id_m:
                    candidate = clean_text(id_m.group(1))
                    if _is_day_header_id(candidate):
                        continue
                    if candidate not in seen:
                        seen.append(candidate)
        if len(seen) == 1:
            result[date_id] = seen[0]
        # NOTE: zero matches fall through to the label/active fallbacks
        # below; multiple distinct checked inputs mean ambiguous markup, so
        # the day is deliberately left unrecorded instead of guessing
        # (last-wins recorded the wrong meal).

        # Also check labels and active elements if not already found from inputs
        if date_id not in result:
            for lm in label_checked_pattern.finditer(div_chunk):
                candidate = clean_text(lm.group(1))
                if not _is_day_header_id(candidate):
                    result[date_id] = candidate
            for lm in label_checked_pattern2.finditer(div_chunk):
                candidate = clean_text(lm.group(1))
                if not _is_day_header_id(candidate):
                    result[date_id] = candidate
            for em in element_checked_pattern.finditer(div_chunk):
                candidate = clean_text(em.group(1))
                if not _is_day_header_id(candidate):
                    result[date_id] = candidate
            for em in element_checked_pattern2.finditer(div_chunk):
                candidate = clean_text(em.group(1))
                if not _is_day_header_id(candidate):
                    result[date_id] = candidate

    return result
