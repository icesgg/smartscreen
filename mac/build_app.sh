#!/bin/bash
# build_app.sh - SmartScreen.app 을 만들고 SmartScreen-mac.zip 으로 묶는다.
#
# Windows 판의 do_build.bat + make_dist.bat 에 해당한다. macOS 에서만 돈다
# (Xcode 명령줄 도구가 있어야 한다). CI(.github/workflows/mac.yml)가 이걸 부른다.
#
#   bash mac/build_app.sh            # 유니버설(arm64+x86_64) 릴리스 빌드
#   bash mac/build_app.sh --native   # 이 Mac 의 아키텍처만 (빠르다)
#
# 결과:
#   mac/dist/SmartScreen.app
#   mac/dist/SmartScreen-mac.zip   (SmartScreen.app + 설치 안내.txt)
#
# 버전은 client/version.h 의 세 숫자다 - Windows 판과 같은 번호를 쓴다. 그 값이
# Info.plist 의 CFBundleShortVersionString 이 되고, 앱은 그걸 자기 버전으로 믿는다.
# 빌드 스크립트의 보고를 믿지 말라는 교훈(NEXT_SESSION.md 함정)대로, 끝에서 만든
# 실행 파일을 직접 돌려 버전을 대조한다.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$HERE"

ver_part() {
    sed -n "s/^#define SS_VERSION_$1[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p" "$ROOT/client/version.h" | head -n1
}
MAJOR="$(ver_part MAJOR)"; MINOR="$(ver_part MINOR)"; PATCH="$(ver_part PATCH)"
if [ -z "$MAJOR" ] || [ -z "$MINOR" ] || [ -z "$PATCH" ]; then
    echo "client/version.h 에서 버전을 읽지 못했다" >&2
    exit 1
fi
VERSION="$MAJOR.$MINOR.$PATCH"
echo "== SmartScreen for macOS $VERSION"

ARCH_ARGS=(--arch arm64 --arch x86_64)
if [ "${1:-}" = "--native" ]; then ARCH_ARGS=(); fi

swift build -c release "${ARCH_ARGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/SmartScreen"
[ -x "$BIN" ] || { echo "실행 파일이 없다: $BIN" >&2; exit 1; }

DIST="$HERE/dist"
APP="$DIST/SmartScreen.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/SmartScreen"
sed "s/__VERSION__/$VERSION/g" "$HERE/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
if [ -f "$HERE/Resources/AppIcon.icns" ]; then
    cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 임시(ad-hoc) 서명. 개발자 인증서가 없으므로 Gatekeeper 는 처음 한 번 막는다
# (설치 안내.txt 1장). 서명이 아예 없으면 Apple Silicon 에서 실행이 안 된다.
codesign --force --deep --sign - --identifier com.icesgg.smartscreen "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 만든 것을 직접 돌려 버전을 본다 (--version 은 창을 띄우지 않고 끝난다).
GOT="$("$APP/Contents/MacOS/SmartScreen" --version | tail -n1)"
if [ "$GOT" != "SmartScreen $VERSION" ]; then
    echo "버전이 다르다: 기대 'SmartScreen $VERSION', 실제 '$GOT'" >&2
    exit 1
fi
lipo -info "$APP/Contents/MacOS/SmartScreen" || true

PKG="$DIST/pkg"
mkdir -p "$PKG"
ditto "$APP" "$PKG/SmartScreen.app"
if [ -f "$HERE/README.txt" ]; then
    cp "$HERE/README.txt" "$PKG/설치 안내.txt"
fi
ditto -c -k --sequesterRsrc "$PKG" "$DIST/SmartScreen-mac.zip"
rm -rf "$PKG"

echo "== $DIST/SmartScreen-mac.zip"
shasum -a 256 "$DIST/SmartScreen-mac.zip" "$APP/Contents/MacOS/SmartScreen"
echo "$VERSION" > "$DIST/VERSION"
