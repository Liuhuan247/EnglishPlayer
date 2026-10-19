#!/bin/bash
# 打出一个可双击的 EnglishPlayer.app。libmpv 与 ffmpeg 打进包内，不依赖本机 Homebrew。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
support="$HOME/Library/Application Support/EnglishPlayer"
mpv_src="$support/libmpv"
ffmpeg_src="$support/bin/ffmpeg"
app="$root/dist/EnglishPlayer.app"

if [[ ! -d "$mpv_src" || ! -f "$mpv_src/libmpv.dylib" ]]; then
  echo "找不到 libmpv：$mpv_src" >&2
  exit 1
fi
if [[ ! -x "$ffmpeg_src" ]]; then
  echo "找不到 ffmpeg：$ffmpeg_src" >&2
  exit 1
fi

cd "$root"
swift build -c release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$root/.build/release/EnglishPlayer" "$app/Contents/MacOS/EnglishPlayer"
cp "$ffmpeg_src" "$app/Contents/MacOS/ffmpeg"
cp "$root/scripts/Info.plist" "$app/Contents/Info.plist"
cp "$root/scripts/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$mpv_src/"*.dylib "$app/Contents/Frameworks/"
chmod +x "$app/Contents/MacOS/EnglishPlayer" "$app/Contents/MacOS/ffmpeg"

# 先签依赖，再签应用。临时签名只保证这台电脑能打开。
for lib in "$app/Contents/Frameworks/"*.dylib; do
  codesign --force --sign - "$lib"
done
codesign --force --sign - "$app/Contents/MacOS/ffmpeg"
codesign --force --sign - "$app"
codesign --verify --verbose=2 "$app"

ditto -c -k --keepParent "$app" "$root/dist/EnglishPlayer.zip"
echo "已打包：$app"
echo "压缩包：$root/dist/EnglishPlayer.zip"
