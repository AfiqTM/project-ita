import SwiftUI

// Makes the app's own `.font(.caption)`, `.font(.headline)`, ... use the pixel fonts while the Retro theme is on.
//
// Most screens set a font explicitly, which would otherwise override the default pixel font. These properties have
// the same names as SwiftUI's text styles, so the app's own declarations win (the same way a type declared in the app
// wins over an imported one) and every existing `.font(.caption)` picks them up with no edits in the other files.
// In every other theme they return exactly SwiftUI's own style.
//
// If a build ever reports "ambiguous use of 'caption'" (or another style name), delete this file: Retro then keeps the
// pixel font only for texts that don't set a font, and everything else still works.
extension Font {
    static var largeTitle: Font  { RetroFonts.on ? RetroFonts.font(30, display: true, relativeTo: .largeTitle) : Font.system(.largeTitle) }
    static var title: Font       { RetroFonts.on ? RetroFonts.font(26, display: true, relativeTo: .title) : Font.system(.title) }
    static var title2: Font      { RetroFonts.on ? RetroFonts.font(22, display: true, relativeTo: .title2) : Font.system(.title2) }
    static var title3: Font      { RetroFonts.on ? RetroFonts.font(19, display: true, relativeTo: .title3) : Font.system(.title3) }
    static var headline: Font    { RetroFonts.on ? RetroFonts.font(16, display: true, relativeTo: .headline) : Font.system(.headline) }
    static var subheadline: Font { RetroFonts.on ? RetroFonts.font(15, relativeTo: .subheadline) : Font.system(.subheadline) }
    static var body: Font        { RetroFonts.on ? RetroFonts.font(17, relativeTo: .body) : Font.system(.body) }
    static var callout: Font     { RetroFonts.on ? RetroFonts.font(16, relativeTo: .callout) : Font.system(.callout) }
    static var footnote: Font    { RetroFonts.on ? RetroFonts.font(13, relativeTo: .footnote) : Font.system(.footnote) }
    static var caption: Font     { RetroFonts.on ? RetroFonts.font(12, relativeTo: .caption) : Font.system(.caption) }
    static var caption2: Font    { RetroFonts.on ? RetroFonts.font(11, relativeTo: .caption2) : Font.system(.caption2) }
}
