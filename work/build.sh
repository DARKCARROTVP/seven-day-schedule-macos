#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$ROOT/work"
OUTPUT="$ROOT/outputs"
APP="$OUTPUT/七日日程.app"
CONTENTS="$APP/Contents"
export CLANG_MODULE_CACHE_PATH="$WORK/module-cache"
export SWIFT_MODULECACHE_PATH="$WORK/module-cache"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$WORK/module-cache"

swiftc -parse-as-library -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework UserNotifications \
  -framework ServiceManagement \
  "$WORK/ScheduleBar.swift" \
  -o "$CONTENTS/MacOS/SevenDaySchedule"

swift "$WORK/IconGenerator.swift" "$WORK/icon-1024.png"
sips -s format tiff "$WORK/icon-1024.png" --out "$WORK/AppIcon.tiff" >/dev/null
tiff2icns "$WORK/AppIcon.tiff" "$CONTENTS/Resources/AppIcon.icns"
cp "$WORK/Info.plist" "$CONTENTS/Info.plist"
codesign --force --deep --sign - "$APP"
plutil -lint "$CONTENTS/Info.plist"
codesign --verify --deep --strict "$APP"

echo "$APP"
