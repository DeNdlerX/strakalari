# School calendar presets

Strakaláři works with **any school** that uses the Bakaláři web interface
and **any canteen** on Strava.cz. The only school-specific part is the
calendar used by the Planner and the lunch cutoff:

- holidays and other days off,
- the absence closure dates of both semesters,
- the lunch ordering deadline (time on the previous business day),
- how percentages turn into grades on the Marks tab.

A **preset** fills these in automatically. Without one, choose **Custom days**
(first-run wizard or *Settings → School calendar*) and enter the dates yourself —
everything else works the same.

Presets shipped with the app:

| id | School | Year |
|----|--------|------|
| `gekom_2026_2027` | GEKOM | 2026/2027 |

## Adding a preset without changing the code

Create a JSON file in the `school_presets` folder inside the app's data
folder (the folder that holds `config.json`), e.g.
`school_presets/gymxy_2026_2027.json`:

```json
{
  "id": "gymxy_2026_2027",
  "title_cs": "Gymnázium XY 2026/2027",
  "title_en": "Gymnázium XY 2026/2027",
  "sem1_close": "25.01.2027",
  "sem2_close": "25.06.2027",
  "lunch_cutoff_time": "13:00",
  "marks_percent_bands": [87, 72, 55, 40],
  "ranges": [
    ["28.10.2026", "30.10.2026", "Podzimní prázdniny"],
    ["23.12.2026", "03.01.2027", "Vánoční prázdniny"]
  ],
  "days": [
    ["17.11.2026", "Státní svátek"]
  ]
}
```

- `id`: letters, digits, `_` or `-`; must not be `custom` or an id shipped
  with the app.
- Dates are `DD.MM.YYYY`; `ranges` are inclusive.
- `lunch_cutoff_time` is optional (`HH:MM`); without it the default is 12:00.
  Check your canteen's real deadline — Strava rejects late orders anyway,
  but a wrong value hides days you could still order.

- `marks_percent_bands` is optional: the **top of grades 2, 3, 4 and 5**
  in percent. Copy it from the school's *Tabulka převodu hodnocení …
  z průběžné klasifikace na celkovou*, which lists each grade's top
  (`100,0 | 87,0 | 72,0 | 55,0 | 40,0 0,0`): take the numbers under grades
  **2–5** (`87, 72, 55, 40`). A boundary value belongs to the worse grade,
  as in that table — 87 % is a 2, 40 % is a 5. Without it the Marks tab
  uses 90/75/50/30; a user can still override it on the Marks tab.

Restart the app; the preset then appears in the wizard and in
*Settings → School calendar*. A file with a mistake is skipped and the reason is
printed to the console log.

## Contributing a preset

Add a dict shaped like `GEKOM_2026_2027` to `PRESETS` in
`strakalari/core/school_presets.py`. `tests/test_school_calendar.py`
checks every shipped preset with `validate_preset()`; add a test for the
expected day count as for GEKOM. Please include a link to the school's
published calendar in the pull request.
