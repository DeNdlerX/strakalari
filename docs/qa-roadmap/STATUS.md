# QA & roadmap status

Branch: qa-roadmap · Base: main @ a528acd · Current phase: 1
Next step: B9 (Android: notification permission over the tutorial; background service doesn't start after allowing)

## Items
| ID | Status (todo / doing / done / can't reproduce / blocked) | Commit | Test | Evidence | Notes |
|---|---|---|---|---|---|
| B1 | done | de10797 | `app/test/wizard_live_test.dart` (`B1 wizard excuse templates`) | `build/qa-evidence/B1/before_wizard_templates_390.png`, `build/qa-evidence/B1/after_wizard_templates_cs_390.png`, `build/qa-evidence/B1/after_wizard_templates_en_390.png` | Reuses `TemplateEditor`, keeps `{name, text}` templates and localized labels, preserves edits across rebuilds |
| B2 | done | 99fe14d | `app/test/settings_live_test.dart` (`B2 template editor`) | `build/qa-evidence/B2/before_settings_templates_390.png`, `build/qa-evidence/B2/after_settings_templates_390.png` | Field spacing 12 px, `minLines: 2, maxLines: null`, commit on blur/submit/dispose |
| B3 | done | 1f2d027 | `app/test/settings_live_test.dart` (`B3 light theme switching`) | `build/qa-evidence/B3/before_light_phone.png`, `build/qa-evidence/B3/after_light_phone.png`, `build/qa-evidence/B3/after_dark_phone.png` | Cached `ThemeData` per token set, disabled `AnimatedTheme` tween in `MyApp`, set explicit `Scaffold.backgroundColor: tok.bg`; verified on Pixel 7 Pro |
| B4 | done | f9e7eba | `app/test/activity_view_test.dart` (`B4 run time`) | — | Stores full ISO-8601 timestamp in `finishRun`; `runTime` rejects date-only strings so legacy runs fall back to `finished` rather than `00:00` |
| B5 | done | 3491a63 | `app/test/settings_sections_test.dart` (`B5 school calendar presets`) | `build/qa-evidence/B5/before_settings_calendar_390.png`, `build/qa-evidence/B5/after_settings_calendar_390.png` | Populates `presetOptions` + `custom` in calendar preset picker, supplies `presetCloses` fallback/hint to `cal:sem1`/`cal:sem2` without writing defaults on blur, omits duplicate label `hintText` on `AutosaveField` |
| B6 | done | ef5fdec | `app/test/settings_sections_test.dart` (`B6 notification event labels`) | `build/qa-evidence/B6/before_settings_notifications_390.png`, `build/qa-evidence/B6/after_settings_notifications_390.png` | Translates all 13 `kNotificationEvents` via `Strings.get('notif_$event')` |
| B7 | done | fef6411 | `app/test/wizard_live_test.dart` (`B7 wizard limits retry snackbar`) | — | Returns `bool` from `retryLimitsRefresh()` and shows `already_running` snackbar only when refresh is already running |
| B8 | done | self (B8 commit) | `app/test/wizard_live_test.dart` (`B8 wizard draft field sync`), `app/test/marks_view_test.dart` (`B8 marks band controllers`) | — | Keys `_DraftField` by draft key and syncs unfocused `initial` updates in `didUpdateWidget`; extracts stateful `_BandsCard` owning and disposing band `TextEditingController`s and `FocusNode`s across rebuilds |
| B9 | todo | — | — | — | |
| P1 | todo | — | — | — | |
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

## Questions for the owner / reviewer
- **B1 (answered 2026-11-15):** Configs previously saved by the old wizard bug hold plain strings instead of `{name, text}` template objects. Per the plan they are left untouched and load cleanly in Settings and the send path — owner replied `"connected. I dont think any use it."` (no migration needed).
## Deviations from the plan (each needs reviewer sign-off)
## Phase notes (written at every ⛔: what was done, what's unsure, how to verify)
