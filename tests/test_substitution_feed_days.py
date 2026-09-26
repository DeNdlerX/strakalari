"""The substitution feed never invents days that were not scraped."""



# -- substitution feed never invents unscraped days ---------------------------

def test_feed_does_not_create_days():
    from strakalari.core.schedule import apply_substitution_feed

    timetable = {"22.09.2026": [{"subject": "M", "teacher": "X",
                                 "time": "1 (8:00 - 8:45)"}]}
    feed = [{"day": "1.10.2026", "period": 3, "badge": "O", "time": "10:00 - 10:45",
             "subject_short": "Ch", "description": "Odpadá"}]
    assert apply_substitution_feed(timetable, feed) == 0
    assert list(timetable) == ["22.09.2026"]
