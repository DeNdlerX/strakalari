# QA & roadmap status

Branch: qa-roadmap · Base: main @ a528acd · Current phase: 2
Next step: P2 (wizard password fields show/hide toggle).

## Items
| ID | Status (todo / doing / done / can't reproduce / blocked) | Commit | Test | Evidence | Notes |
|---|---|---|---|---|---|
| B1 | done | de10797, 1ca6ce8, ec6fb87 | `app/test/wizard_live_test.dart` (`B1 wizard excuse templates`) | `build/qa-evidence/B1/before_wizard_templates_390.png`, `build/qa-evidence/B1/after_wizard_templates_cs_390.png`, `build/qa-evidence/B1/after_wizard_templates_en_390.png` | Reuses `TemplateEditor`, keeps `{name, text}` templates and localized labels, preserves edits and unsaved/name-only rows across rebuilds (M1), removed dead line-split template path (S1) |
| B2 | done | 99fe14d, 1ca6ce8 | `app/test/settings_live_test.dart` (`B2 template editor`) | `build/qa-evidence/B2/before_settings_templates_390.png`, `build/qa-evidence/B2/after_settings_templates_390.png` | Field spacing 12 px, `minLines: 2, maxLines: null`, commit on blur/submit/dispose; `_lastStored` snapshot preserves newly added and name-only rows across rebuilds while still applying external config changes (M1) |
| B3 | done | 1f2d027 | `app/test/settings_live_test.dart` (`B3 light theme switching`) | `build/qa-evidence/B3/before_light_phone.png`, `build/qa-evidence/B3/after_light_phone.png`, `build/qa-evidence/B3/after_dark_phone.png` | Phone bug not reproduced (`before_light_phone.png` is already light); widget test caught a 1-frame theme lag and restarted cross-fade animation on rebuilds caused by uncached `ThemeData` equality. Cached `ThemeData` per token set, disabled `AnimatedTheme` cross-fade in `MyApp`, and set explicit `Scaffold.backgroundColor: tok.bg` (M3) |
| B4 | done | f9e7eba | `app/test/activity_view_test.dart` (`B4 run time`) | — | Stores full ISO-8601 timestamp in `finishRun`; `runTime` rejects date-only strings so legacy runs fall back to `finished` rather than `00:00` |
| B5 | done | 3491a63, dcb6d3e | `app/test/settings_sections_test.dart` (`B5 school calendar presets`) | `build/qa-evidence/B5/before_settings_calendar_390.png`, `build/qa-evidence/B5/after_settings_calendar_390.png` | Populates `presetOptions` + `custom` in calendar preset picker, skips save on null or re-picking active preset (M2), supplies `presetCloses` fallback/hint to `cal:sem1`/`cal:sem2` without writing defaults on blur, omits duplicate label `hintText` on `AutosaveField` |
| B6 | done | ef5fdec | `app/test/settings_sections_test.dart` (`B6 notification event labels`) | `build/qa-evidence/B6/before_settings_notifications_390.png`, `build/qa-evidence/B6/after_settings_notifications_390.png` | Translates all 13 `kNotificationEvents` via `Strings.get('notif_$event')` |
| B7 | done | fef6411 | `app/test/wizard_live_test.dart` (`B7 wizard limits retry snackbar`) | — | Returns `bool` from `retryLimitsRefresh()` and shows `already_running` snackbar only when refresh is already running |
| B8 | done | 0bbe48b | `app/test/wizard_live_test.dart` (`B8 wizard draft field sync`), `app/test/marks_view_test.dart` (`B8 marks band controllers`) | — | Keys `_DraftField` by draft key and syncs unfocused `initial` updates in `didUpdateWidget`; extracts stateful `_BandsCard` owning and disposing band `TextEditingController`s and `FocusNode`s across rebuilds |
| B9 | done | aeec9f4, 02ca569, df655ab | `app/test/android_phone_background_test.dart` (`B9 notification permission and background start`), `app/test/settings_sections_test.dart` (`B9 background switch rebuilds`) | `build/qa-evidence/B9/before_dumpsys.txt`, `build/qa-evidence/B9/after_dumpsys.txt`, `build/qa-evidence/B9/before_notif.txt`, `build/qa-evidence/B9/after_notif.txt`, `build/qa-evidence/B9/tutorial_no_dialog.png`, `build/qa-evidence/B9/permission_dialog_after_tutorial.png`, `build/qa-evidence/B9/after_shade.png`, `build/qa-evidence/B9/s4_dokoncit_tutorial_no_dialog.png`, `build/qa-evidence/B9/s4_dokoncit_permission_dialog.png`, `build/qa-evidence/B9/s4_after_allow_dumpsys.txt`, `build/qa-evidence/B9/s4_after_allow_shade.png` | Cause of (b): before `aeec9f4`, `requestNotificationPermission()` returned immediately before the user answered, so `PhoneBackground.sync()` proceeded while the system dialog covered the app and recorded `_on`/`_interval` before calling `startBackground()`, never retrying on failure or permission grant; Settings' `run_in_background` switch also omitted `onChanged?.call()` (original phone exception log unavailable because `.test` is not debuggable via `run-as`). Fixed permission awaiting in `StrakalariChannel`/`MainActivity`, tutorial-before-permission gating via `startPhoneBackground` (S5), `_allowed` tracking, and switch rebuilds (S3). Verified S4 end-to-end on Pixel 7 Pro after clearing `.test` and walking the wizard through **Dokončit** against the demo server. |
| P1 | done | self (P1 commit) | `app/test/wizard_live_test.dart` (`P1 wizard disclaimer phone wording`) | `build/qa-evidence/P1/before_wizard_disclaimer_390.png`, `build/qa-evidence/P1/after_wizard_disclaimer_cs_390.png`, `build/qa-evidence/P1/after_wizard_disclaimer_en_390.png` | Syncs `Strings.isMobile` with `core.isMobile()` in `prepareStartup` and `AppState.refreshTokens` so mobile wording (`v tomto telefonu` / `on this phone`) activates on Android/iOS in cs and en |
| P2 | todo | — | — | — | |
| P3 | todo | — | — | — | |
| P4 | todo | — | — | — | |
| P5 | todo | — | — | — | |
| P6 | todo | — | — | — | |
| P7 | todo | — | — | — | |
| P8 | todo | — | — | — | |
| P9 | todo | — | — | — | |
| P10 | todo | — | — | — | |
| N1 | todo | — | — | — | |
| F1 | todo | — | — | — | Blocked until R2 + D1 |
| F2 | todo | — | — | — | Blocked until R3 + D2 |
| F3 | todo | — | — | — | Blocked until R4 + D3 |
| F4 | todo | — | — | — | Blocked until R5 + D4 |
| F5 | todo | — | — | — | Blocked until R6 + D5 |

## Owner decisions (answers word for word, with date)
- **B1 (2026-11-15):** "connected. I dont think any use it."
- **S4 / B9 (2026-11-16):** "You may do anything with the .test app. I leave the rest on you, you can decide/test"

## Questions for the owner / reviewer
- **B1 (answered 2026-11-15):** Configs previously saved by the old wizard bug hold plain strings instead of `{name, text}` template objects. Per the plan they are left untouched and load cleanly in Settings and the send path — owner replied `"connected. I dont think any use it."` (no migration needed).
- **M3 / B3 (2026-11-16):** Do you still see the light theme ("Vzhled → Světlý") staying dark on your phone? In our `before_light_phone.png` screenshot it was already light, though widget tests caught a 1-frame lag / restarted cross-fade animation on rebuilds.
- **S4 / B9 (answered 2026-11-16):** Owner replied `"You may do anything with the .test app. I leave the rest on you, you can decide/test"`. Cleared `.test`, walked the wizard through **Dokončit** against the demo server, and saved the S4 screenshots and `dumpsys` output.
- **S6 / B9 (2026-11-16):** In `app/lib/platform/startup.dart` (`PhoneBackground.sync`), `_on`, `_interval`, and `_allowed` are still recorded before `await channel.startBackground(...)`, so if `startBackground` throws once it is not retried until a setting or permission state changes. Left unchanged per R1 S6 ("don't change it without the owner's go, because it changes when the service is started") unless requested after R1.

## Deviations from the plan (each needs reviewer sign-off)
- **M3 (B3):** Disabled the `MaterialApp` theme cross-fade (`themeAnimationStyle: AnimationStyle.noAnimation` in `app/lib/main.dart:77`) so `Theme.of(context)` switches in the same frame as `appState.tok` and cannot lag or restart an animation on rapid rebuilds.
- **S2 (B5):** Removed the duplicated label-as-placeholder `hintText` on all `AutosaveField` widgets (`app/lib/features/settings/settings_view.dart:164`) rather than only on the calendar card, because the label is already shown above every field and the same duplication existed across Settings.
- **S3 (B9):** Added `onChanged?.call()` to four additional `saveQuiet` `SwitchListTile` controls (`use_strava`, both `minimize_to_tray` variants, and `gemini_auto_enabled` in `app/lib/features/settings/settings_view.dart`) for the same missing-redraw bug as `run_in_background`, covered by extended tests in `app/test/settings_sections_test.dart`.

## Phase notes (written at every ⛔: what was done, what's unsure, how to verify)
- **2026-11-16 R1 re-review: PASS** — all must-fix and should-fix findings fixed and verified; notes N6–N9 only. Baseline for R2: core 803 passed / 2 skipped, app 687 passed / 1 skipped. See [`reviews/phase-1.md`](reviews/phase-1.md#re-review-2026-11-16).
- **2026-11-16 R1 review fixes (M1–M3, S1–S6, N3):**
  - Fixed M1 (`1ca6ce8`): `_TemplateEditorState` now tracks `_lastStored` separately from unsaved `values` so newly added empty rows and name-only rows survive `AppState` rebuilds while external config updates still reload.
  - Fixed M2 (`dcb6d3e`): `SettingsView` school preset dropdown returns early when `v == null || v == presetId`, with a live `AppState` test verifying zero config saves/mtime changes on dismiss and re-pick.
  - Fixed S1 (`ec6fb87`): removed the dead `excuseTemplates` / `setExcuseTemplatesInitial` / `saveExcuseTemplates` line-split path from `WizardController`.
  - Fixed S3 (`02ca569`) & S5 (`df655ab`): extended `B9 background switch rebuilds` to cover the four extra `saveQuiet` switches and extracted `startPhoneBackground` in `app/lib/platform/startup.dart` so the cold-launch test calls production startup code directly.
  - Verified S4 on Pixel 7 Pro (`io.github.dendlerx.strakalari.test`, cleared with owner permission, built from `df655ab`): walked the wizard against `bakalari_demo_server.py` through **Dokončit**; captured `Vítejte ve Strakalářích` with no dialog covering it (`s4_dokoncit_tutorial_no_dialog.png`), the `POST_NOTIFICATIONS` prompt immediately after tapping *Přeskočit* (`s4_dokoncit_permission_dialog.png`), and `KeepAliveService` foreground + live shade notification immediately after *Allow* (`s4_after_allow_dumpsys.txt`, `s4_after_allow_shade.png`).
  - Updated `STATUS.md` for M3, S2, S6, and N3; all core (`803 passed, 2 skipped`) and app (`687 passed, 1 skipped`) checks pass. Ready for R1 re-review.
- **2026-11-16 R1 review: FAIL** — 3 must-fix (M1 template rows lost on rebuild, M2 B5 dropdown test/save, M3 B3 evidence), 6 should-fix. See [`reviews/phase-1.md`](reviews/phase-1.md).
### Phase 1 (`B1`–`B9` complete, checkpoint ⛔ R1)
- **What was done:** Fixed all nine Phase 1 bugs (`B1`–`B9`) on branch `qa-roadmap` one item per commit with regression tests before fixes: structured template editing and blur/unmount saving (`B1`, `B2`), whole-app light/dark switching without theme lerp artifacts (`B3`), full ISO run timestamps in Activity (`B4`), school calendar presets and fallback defaults in Settings (`B5`), localized notification event labels in cs/en (`B6`), accurate retry `already_running` snackbar detection in the wizard (`B7`), keyed wizard draft fields and stateful `_BandsCard` controllers in Marks (`B8`), and Android tutorial-before-permission gating plus immediate `KeepAliveService` start and reactive Settings switches (`B9`).
- **Deviations / owner decisions:** None outside the plan. Recorded owner decision on `B1` (`"connected. I dont think any use it."`) leaving any previously mis-saved plain-string templates untouched.
- **Unsure / environment limits:** macOS/iOS builds are not runnable on Windows 11 (Dart changes are covered by unit/widget tests; marked unverified natively). For `B9` phone testing, `.test` data was kept intact (not wiped via `pm clear`) and verified by replaying tutorials (`Přehrát návody znovu`), revoking `POST_NOTIFICATIONS`, cold-launching, skipping the intro tutorial, tapping *Allow*, and verifying `KeepAliveService` and its notification in `dumpsys` and the notification shade.
- **How to verify:**
  1. From repo root: `dart pub get --enforce-lockfile`, then `dart analyze` and `dart test` in `packages/strakalari_core`, and `flutter analyze` and `flutter test` in `app`.
  2. Inspect visual & phone evidence in `build/qa-evidence/` (`B1`, `B2`, `B3`, `B5`, `B6`, `B9`).
  3. On Pixel 7 Pro (`io.github.dendlerx.strakalari.test`), confirm cold startup with `tutorials_done: []` and revoked `POST_NOTIFICATIONS` shows *Vítejte ve Strakalářích* first, prompts for notifications immediately after skipping/finishing the tutorial, and starts `KeepAliveService` immediately upon *Allow*.
