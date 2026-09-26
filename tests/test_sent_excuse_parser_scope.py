"""The sent-excuse parser only reads dates and hours inside the detail header."""



# -- sent-excuse parser stays inside the header ------------------------------

def test_sent_excuse_hours_must_follow_their_date():
    from strakalari.core.extractors.bakalari import extract_sent_excuses

    html = ('<div data-testid="komens-message-detail-header">Od: 7.9.2026<br>'
            'Do: 9.9.2026</div><div>pozdní příchod (1. hod.). Do: 12.9.2026 (3. hod.)</div>')
    assert extract_sent_excuses(html) == [
        {"type": "pure days", "starting_day": "07.09.2026", "ending_day": "09.09.2026"}]


def test_sent_excuse_accepts_spaced_dates():
    from strakalari.core.extractors.bakalari import extract_sent_excuses

    html = '<div data-testid="komens-message-detail-header">Od: 7. 9. 2026 Do: 9. 9. 2026</div>'
    assert extract_sent_excuses(html)[0]["ending_day"] == "09.09.2026"
