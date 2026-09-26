"""Login fields are cleared before typing (and clearing honors cancel)."""

import pytest



# -- login fields are cleared before typing ----------------------------------

class _Field:
    def __init__(self, value="", fill_works=True):
        self.value = value
        self.fill_works = fill_works

    def fill(self, text):
        if not self.fill_works:
            raise RuntimeError("fill ignored")
        self.value = text

    def press(self, key):
        if key == "Delete":
            self.value = ""


@pytest.mark.parametrize("fill_works", [True, False])
def test_clear_input_empties_field(fill_works):
    from strakalari.core.helpers import clear_input

    field = _Field("1234", fill_works=fill_works)
    clear_input(field)
    assert field.value == ""


def test_clear_input_propagates_cancel():
    from strakalari.core.helpers import clear_input

    class _Cancelled(_Field):
        def fill(self, text):
            raise InterruptedError("cancelled")

    with pytest.raises(InterruptedError):
        clear_input(_Cancelled("x"))
