# QA & roadmap status

Branch: qa-roadmap · Base: main @ a528acd · Current phase: 1
Next step: B3 (light theme Vzhled → Světlý stays dark on phone)

## Items
| ID | Status (todo / doing / done / can't reproduce / blocked) | Commit | Test | Evidence | Notes |
|---|---|---|---|---|---|
| B1 | done | self (B1 commit) | `app/test/wizard_live_test.dart` (`B1 wizard excuse templates`) | `build/qa-evidence/B1/before_wizard_templates_390.png`, `build/qa-evidence/B1/after_wizard_templates_cs_390.png`, `build/qa-evidence/B1/after_wizard_templates_en_390.png` | Reuses `TemplateEditor`, keeps `{name, text}` templates and localized labels, preserves edits across rebuilds |
| B2 | done | 99fe14d | `app/test/settings_live_test.dart` (`B2 template editor`) | `build/qa-evidence/B2/before_settings_templates_390.png`, `build/qa-evidence/B2/after_settings_templates_390.png` | Field spacing 12 px, `minLines: 2, maxLines: null`, commit on blur/submit/dispose |
| B3 | todo | — | — | — | |
| B4 | todo | — | — | — | |
| B5 | todo | — | — | — | |
| B6 | todo | — | — | — | |
| B7 | todo | — | — | — | |
| B8 | todo | — | — | — | |
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
## Questions for the owner / reviewer
- **B1:** Configs previously saved by the old wizard bug hold plain strings instead of `{name, text}` template objects. Per the plan they are left untouched and load cleanly in Settings and the send path — do you want a migration later, or leave users to rename them manually?
## Deviations from the plan (each needs reviewer sign-off)
## Phase notes (written at every ⛔: what was done, what's unsure, how to verify)
