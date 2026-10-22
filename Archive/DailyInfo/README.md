# Daily summary (archived)

The "Daily summary" page (swipe right from My courses): class changes (cancelled / online / another venue /
rescheduled) read from announcements by an AI step, plus entries you add yourself.

It is kept here **only as a backup**. This folder is outside the `Sources` folder that XcodeGen builds, so none of it is
compiled or shipped, and the app no longer refers to it. Nothing here is touched by later updates.

Files
- `DailyInfo.swift`      model, store, AI classification, rules
- `DailyInfoView.swift`  `CoursesHome` (the swiping container), the page, rows and the add/edit sheet
- `archive-hooks.patch`  the three small edits that were removed from `Sources/MainViews.swift`
                         (My courses root, the unread dot, the store reference)

To bring it back
1. `git mv Archive/DailyInfo/DailyInfo.swift Archive/DailyInfo/DailyInfoView.swift Sources/`
2. `git apply -R Archive/DailyInfo/archive-hooks.patch`   (if MainViews.swift has changed a lot since, make the
   same three edits by hand: `CoursesHome()` instead of `CoursesView()`, the `daily` store, the accent dot)
3. run `xcodegen`
