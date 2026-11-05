#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
res=../android/app/src/main/res
background='#0F766E'

# Rasterize the approved vector once; all consumers share this silhouette.
magick -background none logo.svg -depth 8 -strip mark.png
mkdir -p ../assets/branding ../../integrations/browser-extension/icons

icon() {
    local size=$1 mark=$2 output=$3
    magick mark.png -trim +repage -resize "${mark}x${mark}" \
        -gravity center -background "$background" -extent "${size}x${size}" \
        -alpha remove -alpha off -depth 8 -strip "$output"
}

for spec in mdpi:48:108:50 hdpi:72:162:75 xhdpi:96:216:100 xxhdpi:144:324:150 xxxhdpi:192:432:200; do
    IFS=: read -r density legacy canvas mark <<< "$spec"
    mkdir -p "$res/mipmap-$density"
    magick mark.png -trim +repage -resize "${mark}x${mark}" \
        -gravity center -background none -extent "${canvas}x${canvas}" \
        -depth 8 -strip "$res/mipmap-$density/ic_lifenizer_foreground.png"
    icon "$legacy" "$((legacy * 71 / 100))" "$res/mipmap-$density/ic_lifenizer.png"
done

icon 1024 728 icon.png
icon 512 364 android/play-store-icon.png
icon 512 364 ../assets/branding/logo.png
for size in 192 512; do
    icon "$size" "$((size * 71 / 100))" "../web/icons/Icon-$size.png"
    # The complete mark fits inside the maskable icon's central 80% circle.
    icon "$size" "$((size * 60 / 100))" "../web/icons/Icon-maskable-$size.png"
done
icon 64 46 ../web/favicon.png
icon 192 136 ../../landing/icon.png
icon 64 46 ../../landing/favicon.png
for size in 16 32 48 128; do
    icon "$size" "$((size * 75 / 100))" "../../integrations/browser-extension/icons/icon-$size.png"
done
