"""Strava ordering over HTTP: staged changes, one save, verified against a fresh menu.

Everything here spends or refunds the student's money. Like the web app,
:meth:`OrderingMixin.order` only stages a change (with the page's own
checks: order deadline, cancel deadline, balance); nothing reaches Strava
until :meth:`OrderingMixin.save_confirm` posts the changes once and
confirms them by reloading the menu. A failed run never saves anything.
"""

import re
from datetime import datetime


#: Strava's "not enough money on the account" warning (code 5005).
LOW_BALANCE_CODE = "5005"

_MEAL_ID_RE = re.compile(r"^(table\d+)&(-?\d+)&\d+$")

#: The order sheet the web app saves for canteens on the older backend
#: (``s5url`` empty), entity-encoded exactly as it sends it.
_ORDER_SHEET_HEAD = (
    '&lt;?xml version="1.0" encoding="UTF-8"?&gt;\n  &lt;VFPData&gt;\n'
    '     &lt;xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema" '
    'xmlns:msdata="urn:schemas-microsoft-com:xml-msdata" id="VFPData"&gt;\n'
    '        &lt;xsd:element name="VFPData" msdata:IsDataSet="true"&gt;\n'
    '           &lt;xsd:complexType&gt;\n'
    '              &lt;xsd:choice maxOccurs="unbounded"&gt;\n'
    '                 &lt;xsd:element name="rozpisobjednavek" minOccurs="0" maxOccurs="unbounded"&gt;\n'
    '                    &lt;xsd:complexType&gt;\n'
    '                       &lt;xsd:sequence&gt;\n'
    '                          &lt;xsd:element name="datum" type="xsd:date" /&gt;\n'
    '                          &lt;xsd:element name="druh"&gt;\n'
    '                             &lt;xsd:simpleType&gt;\n'
    '                                &lt;xsd:restriction base="xsd:string"&gt;\n'
    '                                   &lt;xsd:maxLength value="1" /&gt;\n'
    '                                &lt;/xsd:restriction&gt;\n'
    '                             &lt;/xsd:simpleType&gt;\n'
    '                          &lt;/xsd:element&gt;\n'
    '                          &lt;xsd:element name="pocet"&gt;\n'
    '                             &lt;xsd:simpleType&gt;\n'
    '                                &lt;xsd:restriction base="xsd:decimal"&gt;\n'
    '                                   &lt;xsd:totalDigits value="5" /&gt;\n'
    '                                   &lt;xsd:fractionDigits value="0" /&gt;\n'
    '                                &lt;/xsd:restriction&gt;\n'
    '                             &lt;/xsd:simpleType&gt;\n'
    '                          &lt;/xsd:element&gt;\n'
    '                       &lt;/xsd:sequence&gt;\n'
    '                    &lt;/xsd:complexType&gt;\n'
    '                 &lt;/xsd:element&gt;\n'
    '              &lt;/xsd:choice&gt;\n'
    '              &lt;xsd:anyAttribute namespace="http://www.w3.org/XML/1998/namespace" processContents="lax" /&gt;\n'
    '           &lt;/xsd:complexType&gt;\n'
    '        &lt;/xsd:element&gt;\n'
    '     &lt;/xsd:schema&gt;'
)


def order_sheet(changes: list) -> str:
    """The ``xml`` of ``/api/saveOrders``: one row (date, meal kind, count) per change."""
    rows = "".join(
        f"&lt;rozpisobjednavek&gt;\n&lt;datum&gt;{c['date']}&lt;/datum&gt;\n&lt;druh&gt;{c['druh']}"
        f"&lt;/druh&gt;\n&lt;pocet&gt;{c['pocet']}&lt;/pocet&gt;\n&lt;/rozpisobjednavek&gt;"
        for c in changes)
    return _ORDER_SHEET_HEAD + rows + "\n&lt;/VFPData&gt;"


def _number(value, default=None):
    try:
        return float(str(value).replace(",", "."))
    except (TypeError, ValueError):
        return default


def _moment(value):
    try:
        return datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None


class OrderingMixin:
    """Mixin of :class:`~.strava_client.StravaClient`; uses its session state."""

    # -- Staged state ---------------------------------------------------------
    def _locate(self, meal_id):
        """``(table, index)`` of a menu meal id (``table3&2&0``), or None."""
        match = _MEAL_ID_RE.match(str(meal_id or ""))
        if not match:
            return None
        table, ident = match.group(1), match.group(2)
        for index, meal in enumerate((self.menu or {}).get(table) or []):
            if str(meal.get("id")) == ident:
                return table, index
        return None

    def _count(self, table, index) -> int:
        """The meal's count with the staged changes applied."""
        for change in self._pending:
            if change["table"] == table and change["index"] == index:
                return change["pocet"]
        try:
            return int(self.menu[table][index].get("pocet") or 0)
        except (KeyError, IndexError, TypeError, ValueError):
            return 0

    def _stage(self, table, index, count) -> None:
        for change in self._pending:
            if change["table"] == table and change["index"] == index:
                change["pocet"] = count
                return
        original = int(self.menu[table][index].get("pocet") or 0)
        self._pending.append({"table": table, "index": index, "pocet": count, "prev": original})

    def _balance_after_changes(self):
        """The account balance with the staged changes paid / refunded (None when unknown)."""
        balance = _number((self.user or {}).get("konto"))
        if balance is None:
            return None
        for change in self._pending:
            price = _number(self.menu[change["table"]][change["index"]].get("cena"), 0.0)
            balance -= (change["pocet"] - change["prev"]) * price
        return balance

    def is_food_ordered(self, day_food_identifier):
        if not day_food_identifier or "&-1&" in str(day_food_identifier):
            # The day control never reads ordered; the day's meals tell.
            return False
        where = self._locate(day_food_identifier)
        return bool(where) and self._count(*where) > 0

    def _verified(self, day_food_identifier) -> bool:
        """Staged-state check; never raises."""
        try:
            return bool(self.is_food_ordered(day_food_identifier))
        except Exception:
            return False

    # -- Order / cancel -------------------------------------------------------
    def _refuse(self, code: str, text: str) -> bool:
        self.last_notice = f"Warning [{code}] {text}"
        return False

    def _supported_backend(self) -> bool:
        if self.s5url:
            # Canteens on the newer backend stage every click on the server
            # (/api/pridejJidloS5); not implemented — never guess with money.
            self.log("Warning: this canteen uses Strava's newer backend; ordering over HTTP "
                     "is not supported for it yet — nothing changed.")
            return False
        return True

    def _cancel_day(self, table) -> bool:
        """Stages a whole-day cancel (every ordered meal of the day to 0)."""
        meals = (self.menu or {}).get(table) or []
        ordered = [i for i in range(len(meals)) if self._count(table, i) > 0]
        if not ordered:
            return True
        if not self._supported_backend():
            return False
        now = datetime.now()
        for index in ordered:
            meal = meals[index]
            deadline = _moment(meal.get("casOdhlaseni"))
            if deadline is not None and now >= deadline:
                self.log(f"Warning: {meal.get('datum')}: the cancel deadline has passed, not cancelling.")
                return self._refuse("5011", f"{meal.get('nazev')}: cancelling is closed.")
        for index in ordered:
            self._stage(table, index, 0)
        self.clicks_made += 1
        return True

    def order(self, day_food_identifier, all_day_identifiers=None) -> bool:
        """Stages one meal as the day's order (or, for ``&-1&``, the day's cancel).

        True when the wanted state is staged (or already held, with no
        change). False — with nothing staged — when the menu does not have
        the meal, its order window closed, or the account cannot pay it
        (``insufficient_balance``). Nothing is sent before :meth:`save_confirm`.
        """
        if not day_food_identifier:
            return False
        self.last_notice = ""
        match = _MEAL_ID_RE.match(str(day_food_identifier))
        if match and match.group(2) == "-1":
            return self._cancel_day(match.group(1))
        where = self._locate(day_food_identifier)
        if where is None:
            self.log(f"Notice: {day_food_identifier} is not on the loaded menu.")
            return False
        table, index = where
        if self._count(table, index) > 0:
            return True
        if not self._supported_backend():
            return False
        meal = self.menu[table][index]
        restriction = str(meal.get("omezeni") or "")
        if meal.get("polevka") == "A" or "B" in restriction or "D" in restriction:
            self.log(f"Notice: {day_food_identifier} cannot be ordered.")
            return False
        now = datetime.now()
        deadline = _moment(meal.get("casKonec"))
        if deadline is not None and now >= deadline:
            return self._refuse("5010", f"{meal.get('nazev')}: ordering is closed.")
        others = [i for i in range(len(self.menu[table])) if i != index and self._count(table, i) > 0]
        for other in others:
            cancel_deadline = _moment(self.menu[table][other].get("casOdhlaseni"))
            if cancel_deadline is not None and now >= cancel_deadline:
                return self._refuse("5011", f"{self.menu[table][other].get('nazev')}: changing is closed.")
        if "E" in restriction:
            # The web app's own check: after paying, the balance must stay
            # at or above the lower of the credit limit and the balance.
            balance = self._balance_after_changes()
            konto = _number((self.user or {}).get("konto"))
            limit = _number((self.user or {}).get("limit"))
            price = _number(meal.get("cena"), 0.0)
            refund = sum(_number(self.menu[table][o].get("cena"), 0.0) * self._count(table, o) for o in others)
            floor = None if konto is None or limit is None else min(limit, konto)
            if balance is None or floor is None or balance + refund - price < floor:
                self.insufficient_balance = True
                currency = (self.user or {}).get("mena") or ""
                self.log(f"Warning: not enough money on the Strava account for {day_food_identifier} "
                         f"(balance {balance} {currency}, meal {meal.get('cena')} {currency}).")
                return self._refuse(LOW_BALANCE_CODE, "Not enough money on the account.")
        self._stage(table, index, 1)
        for other in others:
            self._stage(table, other, 0)
        self.clicks_made += 1
        return True

    def _restore_original(self, failed: list, original_ordered: dict) -> None:
        """Drops every staged change: a failed run never saves anything. Never raises."""
        dropped = len(self._pending)
        self._pending = []
        if dropped:
            self.log(f"Strava: {dropped} unsaved change(s) dropped, nothing was saved.")

    def _find_save_button(self, timeout_ms: int = 0):
        """Truthy: changes are staged until :meth:`save_confirm` saves them."""
        return True

    def _notice_suffix(self) -> str:
        """' — <notice>' for failure logs ("" when there is none)."""
        return f" — Strava says: {self.last_notice}" if self.last_notice else ""

    # -- Save -----------------------------------------------------------------
    def _wanted(self, verify_ids) -> list:
        """``[(date, meal id or None for a cancelled day)]`` the save must produce."""
        wanted = []
        for meal_id in verify_ids or []:
            match = _MEAL_ID_RE.match(str(meal_id))
            if not match or match.group(1) not in (self.menu or {}):
                continue
            meals = self.menu[match.group(1)]
            day = str(meals[0].get("datum"))
            wanted.append((day, None if match.group(2) == "-1" else match.group(2)))
        return wanted

    def _holds(self, wanted: list) -> list:
        """The wanted (date, meal) pairs a fresh menu does NOT show."""
        by_day = {str(meals[0].get("datum")): meals for meals in (self.menu or {}).values()}
        lost = []
        for day, ident in wanted:
            ordered = {str(m.get("id")) for m in by_day.get(day, []) if int(m.get("pocet") or 0) > 0}
            if (ident is None and ordered) or (ident is not None and ident not in ordered):
                lost.append((day, ident))
        return lost

    def save_confirm(self, verify_ids: list = None) -> bool:
        """Saves the staged changes once; True only when a fresh menu shows them.

        Fail-closed: nothing to verify, a rejected save, or a menu that
        does not show the selections afterwards all return False. The save
        is never repeated.
        """
        if not verify_ids:
            self.log("Warning: Strava save_confirm called with nothing to verify — nothing saved.")
            return False
        wanted = self._wanted(verify_ids)
        if len(wanted) != len(verify_ids):
            self.log("Warning: Strava save: a selection is not on the loaded menu — nothing saved.")
            return False
        changes = [c for c in self._pending if c["pocet"] != c["prev"]]
        if not changes:
            self.log("Strava: the selection already matches the web — nothing to save.")
            return not self._holds(wanted)
        if not self._supported_backend():
            return False
        sheet = order_sheet([
            {"date": "-".join(reversed(str(self.menu[c["table"]][c["index"]].get("datum")).split("."))),
             "druh": self.menu[c["table"]][c["index"]].get("druh"), "pocet": c["pocet"]}
            for c in changes])
        from .strava_client import StravaError

        try:
            reply = self._call("/api/saveOrders", {**self._session_body(), "xml": sheet}, relogin=False)
        except InterruptedError:
            raise
        except StravaError as e:
            self.last_notice = e.message
            self.log(f"Warning: Strava did not save the orders ({e.number}): {e.message}")
            return False
        except Exception as e:
            self.log(f"Warning: Strava save failed ({type(e).__name__}: {e}) — checking what went through…")
            reply = None
        if reply is False:
            self.log("Warning: Strava did not save the orders (it answered 'false').")
            return False
        self._pending = []
        try:
            self.fetch_data()
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Warning: could not reload the Strava menu after saving ({type(e).__name__}: {e}) — "
                     "the orders may or may not have been saved; check Strava.")
            return False
        lost = self._holds(wanted)
        if lost:
            self.log(f"Warning: Strava does not show {len(lost)} saved selection(s) after saving: "
                     f"{', '.join(day for day, _ in lost)} — check Strava.")
            return False
        self.log(f"Strava orders saved ({len(changes)} change(s)) and confirmed on the menu.")
        return True
