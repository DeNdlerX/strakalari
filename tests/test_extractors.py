from strakalari.core.extractors.bakalari import extract_absence_percentages
from strakalari.core.extractors.strava import extract_food_data, extract_ordered_food


class TestBakalariExtractor:
    def test_empty_and_none_input(self):
        assert extract_absence_percentages("") == {}
        assert extract_absence_percentages(None) == {}

    def test_extract_absence_percentages_standard(self):
        html = """
        <table>
            <tr>
                <td aria-colindex="1">Matematika</td>
                <td aria-colindex="2">45</td>
                <td aria-colindex="3">5</td>
                <td aria-colindex="4">11,1 %</td>
            </tr>
            <tr>
                <td aria-colindex="1">Český jazyk</td>
                <td aria-colindex="2">30</td>
                <td aria-colindex="3">0</td>
                <td aria-colindex="4">0 %</td>
            </tr>
            <tr>
                <td aria-colindex="1">Anglický jazyk</td>
                <td aria-colindex="2">30</td>
                <td aria-colindex="3">6</td>
                <td aria-colindex="4">20.0%</td>
            </tr>
        </table>
        """
        data = extract_absence_percentages(html)
        assert data["Matematika"] == 11.1
        assert data["Český jazyk"] == 0.0
        assert data["Anglický jazyk"] == 20.0

    def test_extract_absence_preserves_zamecnictvi(self):
        # Crucial test: Ensure subjects containing 'zame' such as Zámečnictví are not dropped!
        html = """
        <table>
            <tr>
                <td aria-colindex="1">Zámečnictví</td>
                <td aria-colindex="2">20</td>
                <td aria-colindex="3">3</td>
                <td aria-colindex="4">15,0 %</td>
            </tr>
        </table>
        """
        data = extract_absence_percentages(html)
        assert "Zámečnictví" in data
        assert data["Zámečnictví"] == 15.0

    def test_extract_absence_excludes_summary_rows(self):
        html = """
        <table>
            <tr>
                <td aria-colindex="1">Fyzika</td>
                <td aria-colindex="4">10,0 %</td>
            </tr>
            <tr>
                <td aria-colindex="1">Celkem</td>
                <td aria-colindex="4">12,5 %</td>
            </tr>
            <tr>
                <td aria-colindex="1">Celková zameškanost</td>
                <td aria-colindex="4">12,5 %</td>
            </tr>
            <tr>
                <td aria-colindex="1">Součet</td>
                <td aria-colindex="4">12,5 %</td>
            </tr>
            <tr>
                <td aria-colindex="1">Průměr</td>
                <td aria-colindex="4">12,5 %</td>
            </tr>
        </table>
        """
        data = extract_absence_percentages(html)
        assert "Fyzika" in data
        assert "Celkem" not in data
        assert "Celková zameškanost" not in data
        assert "Součet" not in data
        assert "Průměr" not in data

    def test_extract_absence_fallback_table(self):
        # Table without aria-colindex attributes (standard HTML table fallback)
        html = """
        <table>
            <thead>
                <tr>
                    <th>Předmět</th>
                    <th>Počet hodin</th>
                    <th>Zameškáno</th>
                    <th>Procenta</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td>Dějepis</td>
                    <td>20</td>
                    <td>2</td>
                    <td>10,0 %</td>
                </tr>
                <tr>
                    <td>Biologie</td>
                    <td>30</td>
                    <td>6</td>
                    <td>20.0%</td>
                </tr>
            </tbody>
        </table>
        """
        data = extract_absence_percentages(html)
        assert data.get("Dějepis") == 10.0
        assert data.get("Biologie") == 20.0


class TestStravaExtractor:
    def test_empty_and_none_input(self):
        assert extract_food_data("") == {}
        assert extract_food_data(None) == {}
        assert extract_ordered_food("") == {}
        assert extract_ordered_food(None) == {}

    def test_extract_food_data(self):
        html = """
        <div id="15.09.2026">
            <label for="table1&1&100">Polévka zeleninová, Kuřecí plátek s rýží</label>
            <label for="table1&2&101">Polévka zeleninová, Čočka na kyselo</label>
            <label for="table1&-1&0">Neobjednáno</label>
        </div>
        """
        data = extract_food_data(html)
        assert "15.09.2026" in data
        day_meals = data["15.09.2026"]
        assert "table1&1&100" in day_meals
        assert "Kuřecí plátek" in day_meals["table1&1&100"]
        assert "table1&2&101" in day_meals
        assert "table1&-1&0" in day_meals
        assert day_meals["table1&-1&0"] == "Neobjednáno"

    def test_extract_ordered_food_checked_attribute(self):
        html = """
        <div id="15.09.2026">
            <input type="radio" id="table1&1&100" name="meal_1" checked>
            <label for="table1&1&100">Kuřecí plátek</label>
            <input type="radio" id="table1&2&101" name="meal_1">
            <label for="table1&2&101">Čočka</label>
        </div>
        """
        ordered = extract_ordered_food(html)
        assert ordered.get("15.09.2026") == "table1&1&100"

    def test_extract_ordered_food_ignores_data_checked_false(self):
        # Crucial test: Ensure data-checked="false" or aria-checked="false" is NOT treated as checked!
        html = """
        <div id="16.09.2026">
            <input type="checkbox" id="table2&1&200" data-checked="false" aria-checked="false">
            <label for="table2&1&200">Guláš</label>
            <input type="checkbox" id="table2&2&201" checked="checked">
            <label for="table2&2&201">Těstoviny</label>
        </div>
        """
        ordered = extract_ordered_food(html)
        assert ordered.get("16.09.2026") == "table2&2&201"

    def test_extract_food_data_single_digit_date(self):
        html = """
        <div id="1.9.2026">
            <label for="table1&1&100">Svíčková na smetaně</label>
        </div>
        """
        data = extract_food_data(html)
        assert "1.9.2026" in data
        assert "Svíčková na smetaně" in data["1.9.2026"]["table1&1&100"]

    def test_extract_ordered_food_active_class_and_single_digit(self):
        html = """
        <div id="5.9.2026">
            <span class="meal_btn active" id="table5&1&500">Objednáno</span>
            <span class="meal_btn" id="table5&2&501">Neobjednáno</span>
        </div>
        """
        ordered = extract_ordered_food(html)
        assert ordered.get("5.9.2026") == "table5&1&500"

    def test_extract_ordered_food_button_aria_label(self):
        # Modern Strava frontend: no inputs, state lives in the meal
        # buttons' aria-labels ("Objednáno" vs "Neobjednáno").
        html = """
        <div id="11.09.2026">
            <button id="table2&amp;-1&amp;0" aria-label="Objednáno - den undefined" class="bg-primary"></button>
            <button id="table2&amp;1&amp;0" aria-label="Objednáno - Rajská,Vepřové maso" class="bg-primary"></button>
            <button id="table2&amp;2&amp;0" aria-label="Neobjednáno - Rajská,Jogurtové knedlíčky" class="bg-gray-400/45"></button>
            <button id="table2&amp;3&amp;0" aria-label="Neobjednáno - Rajská,Šopský salát" class="bg-gray-400/45"></button>
        </div>
        <div id="12.09.2026">
            <button aria-label="Změna pole zakázána - Objednáno - Mrkvová,Kuře" id="table3&amp;1&amp;0" class="DisabledInput bg-primary/70"></button>
            <button aria-label="Změna pole zakázána - Neobjednáno - Mrkvová,Mozeček" id="table3&amp;2&amp;0" class="DisabledInput bg-gray-400/20"></button>
        </div>
        """
        ordered = extract_ordered_food(html)
        # Real meal button wins; the always-"Objednáno" day header is ignored.
        assert ordered.get("11.09.2026") == "table2&1&0"
        # Locked past days still report their (unchangeable) order.
        assert ordered.get("12.09.2026") == "table3&1&0"

    def test_extract_ordered_food_button_all_unordered(self):
        html = """
        <div id="13.09.2026">
            <button id="table4&amp;-1&amp;0" aria-label="Objednáno - den undefined" class="bg-primary"></button>
            <button id="table4&amp;1&amp;0" aria-label="Neobjednáno - A" class="bg-gray-400/45"></button>
            <button id="table4&amp;2&amp;0" aria-label="Neobjednáno - B" class="bg-gray-400/45"></button>
        </div>
        """
        # Day header alone must NOT fabricate an order.
        assert extract_ordered_food(html) == {}


class TestAbsenceDuplicates:
    def test_worst_row_wins(self):
        from strakalari.core.extractors.bakalari import extract_absence_percentages
        html = (
            '<tr><td aria-colindex="1">Matematika</td>'
            '<td aria-colindex="2">x</td><td aria-colindex="3">y</td>'
            '<td aria-colindex="4">12,5 %</td></tr>'
            '<tr><td aria-colindex="1">Matematika</td>'
            '<td aria-colindex="2">x</td><td aria-colindex="3">y</td>'
            '<td aria-colindex="4">18,0 %</td></tr>'
        )
        assert extract_absence_percentages(html) == {"Matematika": 18.0}


class TestFoodDateSpacing:
    def test_spaced_date_id_normalized(self):
        from strakalari.core.extractors.strava import extract_food_data
        html = ('<div id="4. 9. 2026">'
                '<label for="table1&amp;1&amp;0">Rizek</label></div>')
        assert "4.9.2026" in extract_food_data(html)


class TestSingleQuotedButtons:
    HTML = """
    <div id="01.10.2026">
      <button id='table2&1&0' aria-label='Objednáno - Kuře' class='x'></button>
      <button aria-label='Neobjednáno - Ryba' id='table2&2&0' class='y'></button>
    </div>
    """

    def test_single_quotes_detected(self):
        from strakalari.core.extractors.strava import extract_ordered_food
        assert extract_ordered_food(self.HTML) == {"01.10.2026": "table2&1&0"}


def _row(subject, pct_cell):
    return (
        f"<tr><td aria-colindex='1'>{subject}</td>"
        f"<td aria-colindex='2'>x</td><td aria-colindex='3'>y</td>"
        f"<td aria-colindex='4'>{pct_cell}</td></tr>"
    )


def test_garbage_first_row_does_not_block_good_row():
    from strakalari.core.extractors.bakalari import extract_absence_percentages

    html = "<table>" + _row("Matematika", "%") + _row("Matematika", "12,5 %") + "</table>"
    assert extract_absence_percentages(html) == {"Matematika": 12.5}


def test_worst_percentage_still_wins():
    from strakalari.core.extractors.bakalari import extract_absence_percentages

    html = "<table>" + _row("Fyzika", "10 %") + _row("Fyzika", "20 %") + "</table>"
    assert extract_absence_percentages(html) == {"Fyzika": 20.0}


def test_parse_substitutions_reads_decorated_period():
    from strakalari.core.extractors.bakalari import parse_substitutions
    html = (
        '<div data-testid="substitutions-day-header">čtvrtek 17.9.2026</div>'
        '<div data-testid="substitutions-entry">'
        '<div data-testid="substitutions-badge">M</div>'
        '<span data-testid="substitutions-hour-label">3. hodina</span>'
        '<span data-testid="substitutions-time-label">10:05 - 10:50</span>'
        '<div data-testid="substitutions-lesson-info">8.1 | M | VIII</div>'
        '<div data-testid="substitutions-lesson-description">'
        '<span>Změna místnosti: VIII</span></div></div>'
    )
    entries = parse_substitutions(html)
    assert len(entries) == 1
    assert entries[0]["period"] == 3
