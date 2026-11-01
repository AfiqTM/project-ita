# Archived themes: Retro, Red Dead Redemption 2, Notebook dark

These three themes are switched off. They no longer show on the Themes screen and can't be picked. Their code stays in
`Sources` (the palettes, fonts, headings, the Pac-Man and gunshot greeting effects, the alternate app icons), so nothing
else had to change and nothing can break from a half-removed theme.

What happens on a phone that had one of them selected: the app opens in Default (dark) instead. Notebook dark opens as
Notebook (light). The choice is saved again, so it only happens once.

Where it is switched off: `AppTheme.archived` in `Sources/Themes.swift`, and `ThemeFamily.variants` / `ThemeFamily.listed`
(which leave archived themes out). With Notebook dark archived, the Notebook card has no Dark / Light switch.

To bring a theme back
1. In `Sources/Themes.swift`, remove it from `AppTheme.archived`, for example
   `static let archived: Set<AppTheme> = [.retro, .redDead]` brings back Notebook dark.
2. Nothing else: the cards, the switch and the icon follow.

What is not archived: the Default (dark / light), Terminal and Notebook (light) themes.
