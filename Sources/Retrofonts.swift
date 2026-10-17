import SwiftUI
import UIKit
import CoreText

// The pixel fonts of the Retro theme (both are free under the SIL Open Font License; the licence texts are next
// to the fonts in Sources/Fonts):
//   Pixelify Sans  - readable mixed-case pixel font, used for body text
//   Silkscreen     - small-caps style pixel font, used for titles and headings
//
// The .ttf files live in Sources/Fonts. XcodeGen puts them in the app bundle by itself (they are not source files),
// and they are registered here when the app starts, so Info.plist needs no UIAppFonts entry.
// If the files are missing, SwiftUI quietly falls back to the system font, so nothing breaks.
enum RetroFonts {
    static let bodyName = "PixelifySans-Medium"
    static let displayName = "Silkscreen-Regular"

    private static var registered = false

    /// Call once at launch, before the first screen is drawn
    static func register() {
        guard !registered else { return }
        registered = true
        var urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        urls += Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)   // already registered = ignored
        }
    }

    /// True while the Retro theme is the chosen one
    static var on: Bool { ThemeStore.shared.theme.arcade }

    /// A pixel font of a given size; it still grows and shrinks with the user's text-size setting
    static func font(_ size: CGFloat, display: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(display ? displayName : bodyName, size: size, relativeTo: style)
    }

    /// Default font for any text that doesn't set its own
    static var body: Font { font(16, relativeTo: .body) }
}
