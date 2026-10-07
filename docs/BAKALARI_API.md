# Bakaláři web — the requests Strakaláři uses

Strakaláři talks to the school's **Bakaláři web** exactly like a browser
does: the same pages, the same form posts, the same JSON endpoints the
pages call from their own scripts. It never uses the mobile API
(`/api/login`, `/api/3/…`).

Code: `strakalari/core/bakalari_http.py` (session, WebForms helpers),
`bakalari_client.py` + the `bakalari_*` mixins, parsers in
`strakalari/core/extractors/bakalari.py`. Tests run against a fake server
(`tests/fake_bakalari.py`).

**Sources.** Everything here was read from the live web app of one school
(Bakaláři web 2.2.x, October 2026): page HTML, page scripts, and real
replies. Items marked *(code only)* were read from a page script but not
seen in a reply. All example values below are made up.

---

## 1. Basics

### Base URL

The configured URL is whatever the address bar showed. The client keeps
scheme + host + any sub-path and drops page names (`app_root()`):

| Configured | Root |
|---|---|
| `bakaweb.example.cz` | `https://bakaweb.example.cz` |
| `https://bakaweb.example.cz/login` | `https://bakaweb.example.cz` |
| `https://example.cz/bakaweb/next/komens.aspx` | `https://example.cz/bakaweb` |

All paths below are relative to that root.

### Session

- ASP.NET cookie session. One `httpx.Client` keeps the cookies.
- Headers sent: a desktop Firefox `User-Agent`, `Accept-Language: cs,en;q=0.8`.
- **Expired session:** requests are redirected to `/login`. The client treats
  a reply as "logged out" when its final URL path ends with `/login`, the
  status is 401, or an HTML reply contains `id="loginButton"`. Reads then
  log in again and retry once.
- Unknown pages redirect to `/dashboard?e=<message>` (e.g. "Požadovaná
  stránka nebyla nalezena").

### JSON envelope

The JSON endpoints answer `200` with:

```json
{ "success": true, "error": null, "data": … }
```

`success: false` carries the reason in `error`. Grids that the page loads
through a DevExtreme `AspNet.createStore` could also answer a bare list or
`{"data": [...], "totalCount": n}`; the parsers accept all three.

### Two kinds of pages

- **New pages** (`/Timetable`, `/Absence/…`, `/Teaching/…`): Knockout /
  DevExtreme, data from the JSON endpoints below.
- **WebForms pages** (`/next/*.aspx`): server-rendered, state in
  `__VIEWSTATE` & co. inside `<form id="formbaka">`, partial updates through
  DevExpress callbacks (see [section 7](#7-webforms-mechanics)).

---

## 2. Login

### `GET /login`

The login page. With a still-valid session cookie it redirects straight to
`/dashboard` (no form). The client decides by content: the form
(`id="loginButton"`) means "log in"; `/dashboard` means "still logged in";
anything else (a 404, another site) means the configured address is not a
Bakaláři web, and it says so instead of trying to log in.

```html
<form id="formlogin" action="Login">
  <input type="text" name="username">
  <input type="password" name="password">
  <input type="hidden" name="returnUrl">
  <button type="submit" name="login" formaction="/Login" formmethod="post"
          id="loginButton">…</button>
</form>
```

### `POST /Login`

Form-encoded. Fields: `username`, `password`, `returnUrl` (as the form
holds it, usually empty), `login` (empty).

- **Success:** a redirect into the app (`/dashboard`), session cookie set.
- **Failure:** the login page again. The reason, when present, is in an
  `?e=` query parameter or one of `.login-error`, `.validation-summary-errors`,
  `.alert-danger`, `.dx-invalid-message`, `#loginError`. A failed-login page
  was not observed live; the client also scans the page text for
  "nesprávné / neplatné / chybné …".

---

## 3. Timetable

### `POST /Timetable/GetContentData`

What the `/Timetable` page calls (`axios.post`) for every view.

Request (JSON):

```json
{ "term": "cal", "date": "2026-10-05", "selectedClassId": "" }
```

| `term` | View |
|---|---|
| `cal` | the week containing `date` (Monday–Friday) |
| `perm` | the stable ("Stálý") timetable |
| `now`, `next` | this / next week *(page switcher values, not used)* |

The page sends its calendar date; a plain `YYYY-MM-DD` is accepted.

Reply: envelope, `data`:

```text
TimetableDataAvailable, SelectedTeacher, ShowTeacherAbsenceReason, Days,
ShowGroups, ShowRooms, ShowTeachers, Hours, Raster, IsTeachingOverviewEnabled,
ShowTimeline, UserType, ShowBakaLogo, IsIFrame
```

- `Days[]`: `Hours, DayAbbrev, Date, DayOff, DayOffName, PauseGuards,
  HourGuards, GeneralGuards, Absences`
- `Days[].Hours[].Atoms[]`: one per lesson (several when groups split an
  hour). `Atoms[].TooltipDetails` is a **JSON string**, the same object the
  rendered page puts into `data-detail`:

```text
type, subjecttext, assistance, assistancePrev, withAssistance, assistancesCount,
teacher, room, group, theme, notice, changeinfo, homeworks, absencetext,
hasAbsent, absentInfoText, HasPlannedClassification, IsLastRoomLesson,
SubjectName, day, time, IdentCode, absenceType, changeBadgeChar,
infoChangeCode, PlannedClassificationCaption, hourIndex
```

| Field | Example | Notes |
|---|---|---|
| `day` | `"5.10.2026 (pondělí)"` | no zero padding |
| `time` | `"3 (10:05 - 10:50)"` | lesson number first |
| `type` | `"atom"` | `"removed"` for a cancelled lesson, which then has no teacher/subject/room but a `removedinfo` text like `Zrušeno (FG, Novák Jan)` |
| `absenceType` | `"Absent"`, `"NoAbsent"`, … | the student's own absence for that lesson |
| `IdentCode` | `"12026100503T2RD…"` | see below; some atoms have none |

**Stable vs. actual week:** the stable view also carries the current
week's dates. Only `IdentCode` tells them apart: in the stable view the
date part is blank (`"1       003T2RD…"`, i.e. one character then four
spaces); in an actual week it is filled. A reply is the stable view when
every atom with an `IdentCode` has the blank form.

---

## 4. Absence

### `GET /Absence/Continuous`

HTML page. Its script holds the default date range:

```js
DatesInformations = ko.mapping.fromJS({
  "DefaultDateFrom": {"DefaultValue": "2026-09-01T00:00:00+02:00", …},
  "DefaultDateTo":   {"DefaultValue": "2026-10-05T00:00:00+02:00", …}, …});
```

(school year start → today).

### `GET /Absence/Continuous/GetAbsenceBySubjects`

The grid's DevExtreme store, with the page's `loadParams` as the query:

```text
?dateFrom=2026-09-01T00:00:00+02:00&dateTo=2026-10-05T00:00:00+02:00
&lateChecked=false&schoolChecked=false&soonChecked=false
```

Reply: envelope, `data`:

```json
[{ "Name": "Matematika", "LessonCount": 12, "Count": 3, "Percent": 0.25 }]
```

`Percent` is a **0–1 fraction** (= `Count / LessonCount`); the page shows
it ×100 with two decimals.

Also on the page, not used: `/Absence/Continuous/GetAbsenceOverview`,
`/Absence/Continuous/GetDates`.

---

## 5. Subjects, substitutions, grades

### `POST /Teaching/Subjects`

The subject overview grid (`createStore({loadUrl: '', loadMethod: 'POST',
key: 'Id'})` on the same URL). Send `X-Requested-With: XMLHttpRequest`.
Reply: envelope, `data`:

```text
[{ Id, SubjectName, TeacherName, Email, Web, HomePhone, MobilePhone, SchoolPhone }]
```

### `POST /Timetable/substitutions/dates`

Form-encoded:

```text
dateFrom=2026-10-04T22:00:00.000Z&dateTo=2026-10-22T22:00:00.000Z
```

ISO UTC (`Date.toISOString()`). The page sends the Monday of the week of
its "from" date and the Friday of the week of its "to" date; the default
period is "Aktuálních 14 dnů" (today … today + 14 days). The client sends
local midnight of those days.

Reply: envelope, `data` = weeks that have changes:

```text
[{ Title, Changes: [{ Day, ChangeType, HourLabel, TimeLabel, Description,
   BeginTimeLabel, EndTimeLabel, ChangeDisplayType, ChangeLessonInfo, IsSupervision }] }]
```

| Field | Example |
|---|---|
| `Day` | `"pondělí 5.10.2026"` |
| `HourLabel` | `"3"` |
| `TimeLabel` | `"10:05 - 10:50"` |
| `ChangeType` | `Canceled`, `Removed`, `Substitution`, `Added`, `RoomChanged`, `Absence` |
| `ChangeDisplayType` | e.g. `"OriginalTeacher"` |
| `ChangeLessonInfo` | `{ ClassAbbrev, GroupAbbrev, IsClassGroup, SubjectAbbrev, RoomAbbrev }` |

Badges as the page shows them (and the app stores them): `Canceled`,
`Removed` → `O`; `Added` → `N`; `RoomChanged` → `M`; `Absence` → `A`;
`Substitution` → `S`.

### `GET /next/prubzna.aspx` — grades (Klasifikace → Průběžná)

A WebForms page; the marks are in the raw HTML as JSON attributes:

```html
<div data-clasif='{"nazev": "Matematika", "MarkText": "1", "vaha": 10,
                   "udel_datum": "5.9.2026", "caption": "…", …}'>
```

Used: `nazev` (subject), `MarkText`, `vaha` (weight), `udel_datum` (date),
and when filled `id`, `caption` (topic), `poznamkakzobrazeni`,
`VerbalEvaluation`, `strdatum` (test day), `PointsText`, `IsNew`,
`MarkTooltip` ("plánovaná klasifikace" = announced mark, shown as `?`).

---

## 6. Komens (excuses)

### Outbox list

`GET /next/komens.aspx?l=o` — Komens → Odeslané (the menu's own link;
`?l=odeslane` opens the same folder). Other folders: `/next/komens.aspx`
(received), `?l=Concept` (drafts).

What the page holds:

```html
<input type="hidden" name="ctl00$cphmain$hfListType" id="hfListType" value="odeslane">
<span id="cphmain_obdobiLabel">5.9.2026 - 5.10.2026</span>   <!-- default: one month -->
```

The client checks `hfListType` before trusting an empty list (another
folder would read as "nothing sent").

The messages are loaded by a DevExpress callback (`message_list_content.
PerformCallback(JSON.stringify(data))`). Replayed over HTTP:
`POST /next/komens.aspx?l=o`, form-encoded, all fields of `formbaka` from
the raw page plus:

```text
__CALLBACKID    = ctl00$cphmain$message_list_content
__CALLBACKPARAM = c0:{"showRepressed":false,"pageNumber":1,"pageSize":21,
                      "reloadMessages":true,"sortOrder":0,"onlyRating":true,
                      "onlyExcuses":true,"onlySystemMessages":true,
                      "onlyGeneralMessages":true,"onlyUnread":false}
```

- The page uses `pageSize: 20 + 1`; 500 works too.
- `sortOrder`: `0` when sorted by `+date`, else `1`.
- With no filter active the page sets all four `only…` flags to `true`
  (= everything).

Reply (DevExpress callback, see [section 7](#7-webforms-mechanics)):

```html
<div class="komens-messages-wrapper">
  <table data-idmsg="1234567" data-sortdate="0:2026-10-01T07:12:45"
         data-msgtype="OMLUVENKA" data-read="true"> … </table>
  …
</div>
```

`data-msgtype="OMLUVENKA"` marks an excuse.

### Message detail

`POST /Komens/GetMessageDataAsync`, JSON (`application/json`):

```json
{ "idmsg": "1234567", "komensMessageListType": "odeslane" }
```

(`komensMessageListType` = the page's `hfListType`; drafts send
`{"conceptId": …}` instead.)

Reply: envelope, `data`:

```text
CaptionText, Title, Cas, Files, Id, Jmeno, Kind, MessageText, MohuEditovat,
MohuOdpovedet, MohuPotlacit, MohuPotvrdit, MohuSmazat, PoslatNotifikaciOSmazani,
Potvrzeno, PersonChar, PocetFiles, CetlJsem, PotlacilJsem, RatingOfMessage,
RecipientsDontReadName, RecipientsDontConfirmName, RecipientsReadCount,
RecipientsConfirmCount, RecipientsReadName, RecipientsConfirmName, ShowReadCount,
ShowConfirmButton, DateFrom, DateTo, TimeFrom, TimeTo, DateAndTimeVisible,
DateTimeFrom, DateTimeTo, SenderId, ShowAnswerButton, ShowExcuseAbsenceButton,
RecipientType, OtherRecipientsCount, DateTimeToVisible, HourFrom, HourTo
```

For an excuse (`Kind: "OMLUVENKA"`):

| Field | Example |
|---|---|
| `DateFrom`, `DateTo` | `"1.10.2026"` |
| `TimeFrom`, `TimeTo` | `"10:05"`, `"10:50"`: lesson excuses carry their lessons' clock times too |
| `HourFrom`, `HourTo` | lesson excuses: `{ Caption: "3", Begin: "10:05:00", End: "10:50:00", BeginTime: "10:05", EndTime: "10:50", BeginTimeValue: 605, EndTimeValue: 650, Start: 605, Duration: 45, HourIndex: 5, BeginNoFlexi, EndNoFlexi }` |

`Caption` is the lesson number. Whole-day excuse details were not
captured; the client reads "no lessons and no clock times" as whole days,
and "clock times without lessons" as unknown (nothing learned).

### Excuse lessons for a day

`GET /Komens/ExcuseHours?date=2026-10-01` → envelope, `data`:

```json
[{ "Caption": "3", "Begin": 605, "End": 650 }, { "Caption": "4", "Begin": 660, "End": 705 }]
```

Only the student's own lessons that day, minutes since midnight. `Caption`
is the lesson number (the page shows it only when the times match the
bell schedule). The excuse form fills its lesson pickers from this.

### The excuse form

`GET /next/komens_zprava.aspx?l=abs` (Komens → Omluvení absence). A
WebForms page with DevExpress controls:

| Control (client name) | What |
|---|---|
| `cphmain_cmbMessageType` | message type, value `OMLUVENKA` |
| `cphmain_cbExcuseWholeDay`, `cphmain_teachingLesson`, `cphmain_specificTime` | radio buttons: whole days / lessons / clock times |
| `cphmain_excuseFromDate`, `cphmain_excuseToDate` | date edits |
| `comboExcuseFromPeriod`, `comboExcuseToPeriod` | lesson pickers (values = minutes) |
| `cphmain_excuseFromTime`, `cphmain_excuseToTime` | time edits ("clock times" mode) |
| `cphmain_cmbRecipientType`, `cphmain_cmbRecipient` | recipient (`U` = teacher; the class teacher is preselected) |
| `cphmain_cbWithConfirmation` | "require confirmation": the page script forces it **on** for excuses |
| `cphmain_cbMailNotification`, `cphmain_cbCc*` | e-mail / copies, unchecked |
| `cphmain_MessageEditor` | the text (DevExpress HtmlEditor) |
| `ctl00$cphmain$button_poslat` | `<input type="submit" value="Odeslat" onclick="return sendMessage();">` |

**Sending.** `sendMessage()` → `BeforePostback()`: validates the page,
re-enables `cmbRecipient`, `cmbRecipientType`, `cmbMessageType` and
`cbWithConfirmation` (so they are posted) and lets the native submit go:
a **full WebForms postback** of `formbaka` to the same URL, form-encoded,
with `ctl00$cphmain$button_poslat=Odeslat`. There is no JSON send endpoint.

The postback (117 fields in a captured send) is the raw form's fields
plus what the DevExpress controls add in the browser. The fields that
carry the excuse:

| Field | Value |
|---|---|
| `ctl00$cphmain$cbExcuseWholeDay` / `teachingLesson` / `specificTime` | radio state: `C` checked, `U` unchecked, `I` untouched. Whole days: `C`/`I`/`I`; lessons: `U`/`C`/`I` |
| `ctl00$cphmain$excuseFromDate` | `01.10.2026` |
| `ctl00$cphmain$excuseFromDate$State` | `{"rawValue":"1790812800000","useMinDateInsteadOfNull":false}`: the date as **UTC midnight** in ms |
| `ctl00$cphmain$excuseFromDate$DDDState` | closed popup `{"windowsState":"0:0:-1:0:0:0:-10000:-10000:1:0:0:0"}` |
| `ctl00$cphmain$excuseFromDate$DDD$C` | calendar `{"visibleDate":"10/05/2026","initialVisibleDate":"10/05/2026","selectedDates":["10/05/2026"]}` (today when the picker wasn't opened) |
| `comboExcuseFromPeriod_VI`, `ctl00$cphmain$comboExcuseFromPeriod$DDD$L` | `605`: the first lesson's `Begin` |
| `ctl00$cphmain$comboExcuseFromPeriod` | `3 (10:05 - 10:50)`: the picker's text |
| `comboExcuseToPeriod_VI`, `…$DDD$L`, text | the last lesson's `End` (`705`), `4 (11:00 - 11:45)` |
| `…excuseToDate…` | as for "from" |
| `ctl00$cphmain$excuseFromTime$State` (and `To`) | `{"rawValue":"<now in ms>",…}` |
| `cphmain_cmbRecipient_VI` | the preselected teacher's code (from the raw page) |
| `ctl00$cphmain$cbWithConfirmation` | `C` |
| `ctl00$cphmain$cbMailNotification`, `ctl00$cphmain$cbCc…` | `U` |
| `ctl00$cphmain$MessageEditor` | the editor state, below |

For whole-day excuses the lesson pickers still post what the form
preselects: the first lesson of the first day, the last lesson of the
last day.

**Editor state.** `ctl00$cphmain$MessageEditor` =
`EncodeHtml(JSON)` of

```json
{"cssFiles": ["../App_Themes/NextBlueTheme/HtmlEditor/styles.css"],
 "clientState": "ActiveView|6|DesignCurrentWidth|3|100CurrentHeight|3|300IsPercentWidth|1|1ForeColorPalette|0|Ribbon|0|",
 "validationState": "",
 "html": "<EncodeHtml(editor HTML)>"}
```

`cssFiles` and `clientState` come from the editor's `stateObject` in the
raw page (`ASPx.createControl(ASPxClientHtmlEditor,'cphmain_MessageEditor',…)`).
The editor HTML is what `GetHtml()` returns: one `<p>…</p>` per paragraph,
`& < > " '` as `&amp; &lt; &gt; &quot; &#39;`, other characters (diacritics)
as they are. So the HTML is encoded **twice**: `<p>a&b</p>` →
`&amp;lt;p&amp;gt;a&amp;ampx;ampx;b&amp;lt;/p&amp;gt;` inside the field.

**Other client-state fields** (constant shapes, posted by the browser):
`…$DDDState` / `…$DDD$L$State` (`{"CustomCallback":""}`) for every combo,
`…cmbTypeOfRating$State`, `…cplRecipientState`, `…lbRecipients$State`,
`…lbChoosenRecipients$State`, `…pcGroupNameState`, `…deValidityStart$State`
/ `End` (now / now + 14 days) with their `$DDDState` / `$DDD$C`,
`…MessageEditor$TD$T0`, `…MessageEditor$SPC…`, `…MessageEditor$DPPState`,
`pcAttachments_MessageState`, `…pcErrorState`, `…pcWarningState`,
`ctl00$pcConfirmDialogState`, and

| Field | Value |
|---|---|
| `DXScript` | the resource ids of the page's `DXR.axd?r=…` script tags, comma-separated |
| `DXCss` | the page's stylesheet links (`DXR.axd` ones as ids) |
| `DXMVCEditorsValues` | a JS object literal of every editor value, dates as `new Date(2026,9,1)` |

The exact field-by-field builder is `excuse_postback()` in
`strakalari/core/bakalari_excuse.py`.

**Result.** The reply to a successful post was not characterized beyond
"not the login page". The client posts once, never retries, and counts the
excuse as sent only when a new `OMLUVENKA` message with the same dates
(and lessons) appears in the outbox. Anything else is "may have been sent".

**Drafts (not used).** The form autosaves drafts when it is dirty:
`POST /Concepts/SaveConcept` `{messageData: getMessageData(), conceptId}`,
`/Concepts/DeleteConcepts`. `getMessageData()` is a JSON view of the form
(`Title, CopyForClassTeacher, …, DateFrom, DateTo` (ISO), `MessageType,
RecipientType, RequireConfirmation, Text, Recipients, …`). It is only for
drafts; sending is the postback above.

---

## 7. WebForms mechanics

### Posting a form like the browser

`form_fields(html, "formbaka")` returns what a browser submits from the
raw HTML: every named `input` / `select` / `textarea` of the form, in
order, except disabled ones, submit/button/image/reset/file inputs and
unchecked checkboxes/radios; a `select` posts its `selected` option
(else the first). Fields the page's JavaScript adds later (DevExpress
`$State` and friends) are not in the raw HTML; the caller adds them.

### `ASPx.Str.EncodeHtml`

DevExpress runs every client-state value through it before posting:

```text
&amp; → &ampx;   & → &amp;   &quot; → &quotx;   " → &quot;
&lt;  → &ltx;    < → &lt;    &gt;   → &gtx;    > → &gt;
```

(in this order). `dx_encode_html()` / `dx_state()` in `bakalari_http.py`.

### DevExpress callbacks

A control's callback is a `POST` of the page's form fields plus
`__CALLBACKID` (the control's unique id) and `__CALLBACKPARAM` (`c0:` +
the parameter). The reply is not HTML:

```text
123|<state>/*DX*/({'id':0,'result':'…'})
```

`result` is a JavaScript string literal (single quotes; escapes seen:
`\'`, `\-`, `\r`, `\n`, `\t`). A failure carries
`'error':{'message':'…'}` instead. `dx_callback_result()` decodes it.

---

## 8. Other pages seen (not used)

`/dashboard`, `/Marks/Semester`, `/HomeWorks/Student`,
`/Timetable/substitutions` (the substitutions page),
`/Timetable/Substitution/MySubstitutions`, `/core/Events/Agenda/Index`,
`/next/komens_zprava.aspx` (new message), `/next/vyuka.aspx`,
`/next/vychovna.aspx`, `/PersonalData/Overview`, `/Tools/Settings`,
`/About/Personalization/Grant` / `Reject` (cookie consent).
