# Strava.cz — the requests Strakaláři uses

Strava's web app (`https://app.strava.cz`, the site the login on
`strava.cz` leads to) is a Next.js single-page app that talks to its own
JSON endpoints under `/api/`. Strakaláři sends the same requests.

Code: `strakalari/core/strava_client.py` (login, menu),
`strava_ordering.py` (ordering, save), parsers in
`strakalari/core/extractors/strava.py`. Tests run against a fake API
(`tests/test_strava_client.py`).

**Sources.** Read from the live web app (October 2026): its page scripts
and real replies for one canteen on the older backend (**S4**, see below).
Items marked *(code only)* were read from the web app's scripts but not
seen in a reply; nothing for the newer backend (**S5**) was seen live.
All example values below are made up.

---

## 1. Basics

### Request convention

Every call is a `POST` to `https://app.strava.cz/api/<name>` with a JSON
body sent as text, exactly like the web app's `fetch`:

```http
POST /api/objednavky HTTP/1.1
Content-Type: text/plain;charset=UTF-8

{"cislo":"1234","sid":"…", …}
```

- A reply counts when the status is 2xx **or 555**; the body is JSON.
- **Errors** come as a normal reply:

  ```json
  { "state": "error", "number": 13, "message": "…", "backend": "…" }
  ```

  Other statuses → the web app reports `{"state":"error","number":<status>}`.
- **Session gone:** after numbers `13, 15, 10102, 90, 1009, 1010, 1011,
  1014, 30, 10104` the web app logs the user out. Number `20` from
  `resetTabulekS5` / `nactiVlastnostiPA` means the diner is blocked at the
  canteen. The client logs in again once after a session-gone number (reads
  only).
- A reply carrying `newUrl` (or `uzivatel.newUrl`) moves the canteen to a
  new `s5url`; the web app stores it *(code only)*.
- The web app retries network failures up to 3 times, 3 s apart. The
  client retries a read once when the connection broke before any reply,
  and never retries the save.

### Session

There is no cookie session: the web app keeps what `/api/login` returned
in `sessionStorage` and sends it with every call:

| Field | Meaning |
|---|---|
| `cislo` | canteen number |
| `sid` | session id from the login |
| `s5url` | the canteen's S5 backend URL; **empty for S4 canteens** |
| `ignoreCert` | passed back as the login returned it (the web app sends the string it stored) |

`lang`: `"CZ"`, `"SK"` or `"EN"` (from the page locale); the client sends
`"CZ"`.

### Backends: S4 and S5

Canteens run one of two backends behind the same web app:

- **S4** (`s5url` empty, menu rows have `databaze: "S4"`): changes are
  collected in the browser and saved as one order sheet (XML).
- **S5** (`s5url` set): every change is staged on the server first
  (`pridejJidloS5` …), then saved. *(code only)*

Strakaláři reads both, but orders only on S4. On S5 it refuses with a log
message and changes nothing.

---

## 2. Login

### `POST /api/login`

```json
{ "cislo": "1234", "jmeno": "novak", "heslo": "…",
  "zustatPrihlasen": false, "environment": "W", "lang": "CZ" }
```

`environment`: `"W"` web, `"A"` Android app, `"M"` iOS app.

Reply:

```json
{ "sid": "…", "s5url": "", "cislo": "1234", "ignoreCert": false,
  "uzivatel": { "konto": "350", "limit": "0.00", "mena": "Kč",
                "vicenasobny": "false", … },
  "betatest": false }
```

The web app copies every `uzivatel` key into `sessionStorage`. Keys seen
there after a login:

```text
bakalarId, dochazka, editaceJidelnicku, email, id, jmeno, konto, limit, mena,
nazevJidelny, pasivni, pocetJidel, podrobnosti, prihlaska, slabeHeslo, text,
verze, verzeS, vicenasobny, vs, vydej
```

| Key | Meaning |
|---|---|
| `konto` | account balance (string) |
| `limit` | credit limit: how low the balance may go (string, `"0.00"` = no credit) |
| `mena` | currency, e.g. `Kč` |
| `vicenasobny` | `"true"` when more than one portion per meal may be ordered |

A rejected login is an error reply (not observed). With `betatest: true`
the web app hands the session over to `https://stage.app.strava.cz`
*(code only)*.

Not used: the e-mail account login (`/api/loginPA`, `/api/jidelnyPA`, …),
`/api/bakalarLogin`, and `/api/nactiVlastnostiPA`, which re-reads the user's
properties for an existing `sid`.

---

## 3. The menu

### `POST /api/objednavky`

What the orders page (`/`) loads:

```json
{ "cislo": "1234", "sid": "…", "s5url": "", "lang": "CZ",
  "konto": 0, "podminka": "", "ignoreCert": "false" }
```

(Note: `s5url` here, `url` in the other calls.) The page skips the call,
with warning 99, when `sessionStorage.zakazPrihlaskou === "1"` (the
registration form was not sent yet).

Reply: one key per day, `table0`, `table1`, …, in date order, starting
today (11 days were returned). Each is a list of rows:

```json
{
  "table0": [
    { "id": 0, "druh": "P", "polevka": "A", "omezeni": "B", "nazev": "polévka",
      "druh_popis": "polévka", "cena": "0", "pocet": 0,
      "casKonec": "9999-12-31T00:00:00", … },
    { "id": 1, "druh": "1", "polevka": "N", "omezeni": "5E", "pocet": 1,
      "datum": "07.10.2026", "druh_popis": "oběd 1", "druh_chod": "oběd 1",
      "nazev": "Polévka,Hlavní jídlo, příloha", "cena": "45.00",
      "alergeny": [["01", "Obiloviny obsahující lepek    "], ["07", "Mléko   "]],
      "alergeny_text": "-----\r\n01 -Obiloviny obsahující lepek\r\n07 -Mléko",
      "casKonec": "2026-10-06T14:15:00", "casOdhlaseni": "2026-10-06T14:15:00",
      "chod": "C", "databaze": "S4", "zkratkaProduktu": "zkratka",
      "multipleNazev": "Nmeal1", "version": 4, "delsiPopis": "", "alergjson": [""] }
  ],
  "table1": [ … ]
}
```

| Field | Meaning |
|---|---|
| `id` | row index within the day; `0` = the soup row |
| `datum` | `DD.MM.YYYY` |
| `druh` | meal kind: `P` soup, `1`, `2`, `3` … (the order sheet uses it) |
| `druh_popis` | the kind's name (`oběd 1`, `salát`) |
| `nazev` | the dish (soup and main course, comma-separated) |
| `pocet` | portions ordered (`0` / `1`) |
| `cena` | price (string) |
| `omezeni` | restriction letters, see [section 4](#4-ordering) |
| `polevka` | `A` for the soup row (no order control), else `N` |
| `casKonec` | ordering deadline (local time) |
| `casOdhlaseni` | cancelling deadline (local time) |
| `alergeny` | `[[code, name], …]` (names are space-padded) |

S5 rows also carry `veta` (row id), `vetaDieta`, `omezeniObj {obj, zm, bur}`,
`burza {zmena, nabidka, ostatni, poptavka}`, `vydejniMisto {misto}` and
`diety {dieta}` *(code only)*.

### The ids the app uses

The web page's order controls have the id `<day key>&<row id>&0`, e.g.
`table0&1&0`. The app keeps exactly those ids (they are in the cache, the
history and the UI):

- one entry per row except the soup row (`polevka: "A"` or an empty
  `zkratkaProduktu`), text `"<druh_popis> - <nazev>(<codes> )"`, e.g.
  `oběd 1 - Polévka,Hlavní jídlo, příloha(01, 07 )` (no parentheses
  without allergens);
- a day control `<day key>&-1&0` ("cancel this day"), text
  `"Tuesday 06/10/2026"`;
- the ordered meal of a day = the row with `pocet > 0`.

`table0` is always the first day of the reply, so a day's ids change from
one day to the next, just like the page's ids did.

---

## 4. Ordering

### The web app's checks

Before recording a change the web app checks each row:

| Check | Code |
|---|---|
| now ≥ `casKonec` when ordering | warning `5010` (ordering closed) |
| now ≥ `casOdhlaseni` when cancelling an ordered row | warning `5011` (cancelling closed) |
| `omezeni` contains `B` | not orderable, skipped |
| `omezeni` contains `C` and the row is already ordered | warning `5003` |
| `omezeni` contains `D` when ordering | skipped |
| `omezeni` contains `E` when ordering: balance after the order < min(`limit`, `konto`) | warning `5005` (not enough money) |
| `vicenasobny` is not `"true"` | count capped at 1 |

The client applies the same checks (5005 also accounts for the meal a
switch refunds) and stages nothing when one fails.

### Changes

The web app collects changes as `{table, mealIndex, pocet, prevValue}`.
Picking another meal for a day records the new row (`pocet: 1`) and then
the previously ordered row (`pocet: 0`); cancelling a day sets the ordered
row to `0`.

### S4: `POST /api/saveOrders`

```json
{ "cislo": "1234", "sid": "…", "url": "", "xml": "<order sheet>",
  "lang": "CZ", "ignoreCert": "false" }
```

`xml` is the order sheet, entity-encoded (`&lt;` …) exactly as the web
app builds it (`order_sheet()` in `strava_ordering.py` matches it byte for
byte):

```text
&lt;?xml version="1.0" encoding="UTF-8"?&gt;
  &lt;VFPData&gt;
     &lt;xsd:schema … id="VFPData"&gt; … &lt;/xsd:schema&gt;&lt;rozpisobjednavek&gt;
&lt;datum&gt;2026-10-07&lt;/datum&gt;
&lt;druh&gt;2&lt;/druh&gt;
&lt;pocet&gt;1&lt;/pocet&gt;
&lt;/rozpisobjednavek&gt;&lt;rozpisobjednavek&gt;
&lt;datum&gt;2026-10-07&lt;/datum&gt;
&lt;druh&gt;1&lt;/druh&gt;
&lt;pocet&gt;0&lt;/pocet&gt;
&lt;/rozpisobjednavek&gt;
&lt;/VFPData&gt;
```

One `rozpisobjednavek` per change: the day (`YYYY-MM-DD`), the meal kind
(`druh`) and the new count. The full schema header is the constant
`_ORDER_SHEET_HEAD`.

Reply:

- an error reply → not saved (shown as error 2501 with its number and message);
- `false` → not saved (warning 2515);
- otherwise saved: the web app shows "saved" (2516) and updates the
  balance (S4: from its own calculation; S5: `konto` and `produkty` from
  the reply).

The client posts once, never retries, and reports success only when a
freshly loaded menu shows every selection.

**Unsaved changes.** The web app warns when leaving with unsaved changes
(`onbeforeunload`) and remembers them for 24 h (`unsavedOrders`); the
next visit shows "Neuložené objednávky".

### S5 *(code only, not implemented)*

Each click stages the change on the server; `/api/saveOrders` then saves
with `"xml": null`.

| Call | Body (besides `cislo, sid, url, lang, ignoreCert`) |
|---|---|
| `/api/pridejJidloS5` | `veta`, `pocet` |
| `/api/objednejDenS5` | `datum` (`YYYY-MM-DD`), `pocet` (whole day) |
| `/api/zmenVydejniMisto` | `veta`, `vydejniMisto` |
| `/api/zmenDietu` | `veta`, `dieta` |
| `/api/resetTabulekS5` | `vstupniZarizeni` (discards staged changes) |
| `/api/zmenJazyk` | (switches the backend's language) |

The staging replies list the affected rows as `produkt[].$` with `Veta,
Pocet, NelzeObj, NelzeZm, NelzeBur, BurzaZmena, BurzaNabidka,
BurzaOstatni, BurzaPoptavka, VydejniMisto, Dieta, VetaDieta`. Error `18`
means the staged state is stale: the web app warns, resets and reloads.

---

## 5. Other endpoints seen (not used)

`/api/logOut`, `/api/logOutPA`, `/api/messagesGetAmount`,
`/api/messagesGetList`, `/api/messagesGetDetail`, `/api/messagesSetRead`,
`/api/historieKlienta`, `/api/platby`, `/api/qr`, `/api/jidelnaS5`,
`/api/jidelnickyPage`, `/api/orderModalDetails`, `/api/zapisHodnoceniJidel`,
`/api/attendance`, `/api/poctyJidel`, `/api/vydej`, `/api/prodej`,
`/api/potvrzeni`, `/api/userInfo`, `/api/ulozNastaveniKlienta`,
`/api/changePasswordPA`, `/api/sendProtokol`, `/api/logger`,
`/api/patron…` (the `/patron` page).
