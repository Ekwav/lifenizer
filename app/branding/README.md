# Lifenizer identity

The approved mark is the bookmark-stem **L**: an upright bookmark with a V notch,
separated by a small gap from its horizontal foot. Ivory (`#F8F9F5`) on teal
(`#0F766E`). [`approved-source.png`](approved-source.png) is the selected imagegen
artwork; [`prompt.txt`](prompt.txt) records its exact prompt. Unselected drafts
and comparison sheets have been removed.

[`logo.svg`](logo.svg) is the clean vector master tracing the selected two-piece
silhouette. [`mark.png`](mark.png) is its transparent raster and
[`icon.png`](icon.png) is the 1024 × 1024 square brand icon.

Regenerate every packaged image without any model calls (ImageMagick 7 required):

```sh
bash app/branding/generate-icons.sh
```

This updates Android legacy/adaptive/themed icons and the Play Store image,
Flutter's login/header asset, web/PWA icons, website marks/favicons, and browser
extension icons. Android foregrounds fit the central 66 dp safe circle; web
maskable icons fit the central 80% circle. The Linux window loads the Flutter
asset directly; KDE installation installs that same asset in the hicolor theme
as `com.lifenizer.app`, also used by KRunner search results.

Generated files are checked in so builds and installations need no graphics
tools. After changing the palette, keep the generator, Android
`res/values/icon_colors.xml`, and web manifest/theme color in sync.
