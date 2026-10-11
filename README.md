# iTa'leem (iOS, SwiftUI)

Native client for iTa'leem (Moodle) using Moodle's mobile web-service API, styled like the
"iTa'leem AMOLED Dark" userscript (black, #D2B48C accent, glow cards, filter row with Assignments tab).

## Build
1. On a Mac: `brew install xcodegen`
2. In this folder: `xcodegen` (creates `iTaleem.xcodeproj` from `project.yml`)
3. Open it, pick your Apple ID under Signing & Capabilities, run on your iPhone (iOS 16+).

(No XcodeGen? New Xcode project -> iOS App (SwiftUI) -> delete the template files -> drag the
`Sources` files in. Set the display name and force Dark appearance.)

## Login
- **Sign in with iTa'leem (2FA)**: opens the real site in a secure browser sheet
  (ASWebAuthenticationSession) via `admin/tool/mobile/launch.php`. The site handles username,
  password and 2FA, then hands the app a token. Token is stored in the Keychain.
- **Username + password**: `login/token.php`. Works only for accounts without 2FA.

## What's inside
- My courses with All / In progress / Future / Past / Starred / Removed from view / Assignments (count badge)
- Course page: sections, files, folders, forums (announcements), assignments (due/status/grade), Participants, Grades
- Assignments tab = Timeline (next 30 days + 7 days overdue)
- Alerts (notifications), Website tab (full site, dark-themed, auto-logged-in), Profile / sign out
- Any activity without a native screen (quiz, attendance, page...) opens in the dark-themed web view

## Known gaps
- Attendance % tooltip from the userscript is not ported (Moodle has no web-service for it).
- Font is the system font; add Google Sans Flex .ttf files + UIAppFonts if you want it.
- Requires iTa'leem's mobile web services to be enabled (the official Moodle app needs the same).

## No Mac? (Windows)
1. Create a GitHub repo and upload the contents of this folder to its root (including `.github`).
2. Actions tab -> "Build IPA" -> Run workflow. Download the `iTaleem-ipa` artifact (unzip -> iTaleem.ipa).
3. Install it with Sideloadly (Windows) using your Apple ID. Free accounts must re-sign every 7 days.
If the build fails, the Actions log shows the Swift errors.
