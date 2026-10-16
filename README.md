# iTa'leem (iOS, SwiftUI)

Native client for iTa'leem (IIUM Moodle) using Moodle's mobile web-service API, styled like the
"iTa'leem AMOLED Dark" userscript (true black, #D2B48C tan accent, glow cards, filter row with an Assignments tab).

## Features

### Courses
- My courses with All / In progress / Future / Past / Starred / Removed from view / Assignments (count badge)
- Default tonal cover for courses without an image
- Course page: sections, files, folders, pages, forums (announcements), assignments (due / status / grade), Participants, Grades
- Participants open a profile screen (photo, Message button, About me / Courses / More details, depending on the site's privacy settings)
- Any activity without a native screen (quiz, ...) opens in the dark-themed web view

### Assignments
- Assignments tab = timeline (next 30 days + 7 days overdue) with a count badge
- Built-in submission: submit, edit and remove, with the lecturer's attached files and a share button
- Changes made with no internet are kept and sent when the connection returns; if the site refuses one (deadline passed, locked) it stays on the assignment with the reason, Retry and Discard

### Attendance
- Attendance screen with the records and the maximum possible attendance at the top
- Home-screen widget (small / medium / large) showing the maximum possible attendance of every subject, refreshed in the background

### Alerts and messages
- Alerts tab (notifications) with an unread badge; the app icon badge = unread alerts + unread chats
- Messages: chat list, conversations, reply, select and delete for me, start a chat from a profile
- Local notifications for to-dos due in 24 h, assignments due in under 24 h, and new messages / alerts / announcements

### Study tools (Others tab)
- To-Do List with history, linked to your subjects ("Section" courses), plus a To-Do tab on each course page
- Final Exam Calculator (CAMS marks needed in the final exam), also on each course's Grades page
- My Drive: browse Google Drive inside the app (native preview), pin items and save files to a subject
- Sync with the iTa'leem userscript through one file in your Google Drive (`iTaleem-sync.json`): to-dos, CAMS marks, pins and saved files merge both ways, newest change wins

### Themes
- Others > Themes: pick the look of the app (AMOLED Dark, Light); the whole app cross-fades to the new theme straight away and the choice is remembered
- Each theme is a `Palette` in `Theme.swift` plus an entry in `Themes.swift`

### Website
- Website tab: the full iTa'leem site in a normal browser view that stays logged in and keeps its page when you switch tabs

### Offline
- **Offline support** (Others, on by default): course lists, course contents, grades, announcements, notifications and attendance pages are saved and open with no internet, with a small "Offline" pill. Updated about every 12 hours (random 10-14 h); course contents are only downloaded again when the site says they changed. Optional "Download on mobile data" switch.
- **Download course files** (inside Offline support, off by default): saves PDFs, slides and attachments (resources, folder files, page attachments; no videos or links).
  - Own Wi-Fi / mobile-data rule ("Files on mobile data", off by default), separate from the general one
  - Per-file limit: 10 MB (default), 25 MB or 50 MB
  - A file is downloaded once; fetched again only when its last-modified time changes
  - Press and hold a file > **Download** saves it whatever its size (works with the switch off too); **Remove download** deletes it
  - **Delete downloaded files** removes only these files; offline data stays. Files live in `Application Support/OfflineFiles`
  - The file viewer opens the saved copy when there is no internet

## Setup

### Build
1. On a Mac: `brew install xcodegen`
2. In this folder: `xcodegen` (creates `iTaleem.xcodeproj` from `project.yml`)
3. Open it, pick your Apple ID under Signing & Capabilities, run on your iPhone (iOS 16+).

(No XcodeGen? New Xcode project -> iOS App (SwiftUI) -> delete the template files -> drag the
`Sources` files in. Set the display name and force Dark appearance.)

### No Mac? (Windows)
1. Create a GitHub repo and upload the contents of this folder to its root (including `.github`).
   Make sure every file in `Sources`, `Shared` and `Widget` is uploaded; a missing file shows up as "cannot find ... in scope".
2. Actions tab -> "Build IPA" -> Run workflow. Download the `iTaleem-ipa` artifact (unzip -> iTaleem.ipa).
3. Install it with Sideloadly (Windows) using your Apple ID. Free accounts must re-sign every 7 days.
If the build fails, the Actions log shows the Swift errors.

### Google Drive (My Drive and sync)
Paste an OAuth **iOS** client ID from Google Cloud Console into the setup section at the top of `Sources/MyDrive.swift`.

## Login
- **Sign in with iTa'leem (2FA)**: opens the real site in a secure browser sheet
  (ASWebAuthenticationSession) via `admin/tool/mobile/launch.php`. The site handles username,
  password and 2FA, then hands the app a token. Token is stored in the Keychain.
- **Username + password**: `login/token.php`. Works only for accounts without 2FA.

## Known gaps
- The website's attendance % tooltip is not ported; the app works out the maximum possible attendance itself.
- Font is the system font; add Google Sans Flex .ttf files + UIAppFonts if you want it.
- Requires iTa'leem's mobile web services to be enabled (the official Moodle app needs the same).
- Images embedded inside page text still need internet; only attachment files are saved offline.
