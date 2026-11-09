# Android icons

The approved bookmark-stem L comes from the [shared vector master](../logo.svg).
`play-store-icon.png` is the opaque 512 × 512 store asset.

Regenerate packaged PNGs without another model call (requires ImageMagick 7):

```sh
bash app/branding/generate-icons.sh
```

The script writes all five legacy launcher densities (48–192 px) and transparent
adaptive foregrounds (108–432 px) under `app/android/app/src/main/res/`.
The adaptive foreground fits inside the central 66 dp safe circle on its 108 dp
canvas. Android 8+ supplies the launcher mask; Android 13+ can tint the same alpha
silhouette for themed icons. The manifest and launcher shortcuts use
`ic_lifenizer`; the original Flutter template assets are preserved.

The generator also updates all other app/website/extension assets; see the
[shared branding instructions](../README.md).

Resource check (from `app/android`):

```sh
./gradlew :app:processDebugResources --offline --console=plain
```
