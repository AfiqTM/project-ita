# Siri / Shortcuts (archived)

Ask Siri (or use the Shortcuts app): assignments due, lecturer, section, absences left before attendance drops under 80%,
class cancelled / moved (read from announcements), add a to-do, open a submission. Plus an iOS 18+ Spotlight index of
assignments, announcements and attendance notes (App Entities) for Apple Intelligence.

It is kept here **only as a backup**. This folder is outside the `Sources` folder that XcodeGen builds, so none of it is
compiled or shipped, and the app no longer refers to it.

Files
- `Siri.swift`           subjects, intents (`AbsencesLeftIntent` ...), `SiriRouter`, `iTaleemShortcuts` phrases
- `SiriIndex.swift`      `SiriNotes` store, `StudyItemEntity` / `StudyItemQuery` (Spotlight index)
- `archive-hooks.patch`  the edits that were removed from `App.swift` (sign-out clear), `MainViews.swift` (submission sheet,
                         subject refresh, donate), `Offline.swift` (announcement donate), `AttendanceSync.swift`
                         (attendance notes), `project.yml` (alternative app names "Ita" / "iTaleem" / "Italeem"), `README.md`

Known problem when it was archived: on iOS 27 the spoken phrases ("... in iTa'leem") went to Siri's own AI / the website instead
of the app's intents. The actions did appear and run correctly in the Shortcuts app, so a personal shortcut with its own name
worked. Not solved.

To bring it back
1. `git mv Archive/Siri/Siri.swift Archive/Siri/SiriIndex.swift Sources/`
2. `git apply -R Archive/Siri/archive-hooks.patch`
3. run `xcodegen`
