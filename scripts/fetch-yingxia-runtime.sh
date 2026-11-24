#!/bin/bash
set -euo pipefail

# 从 Yingxia 官方 DMG 提取 macOS JavaHost，供 tvbox-swift 的 type=3 JAR 源使用。
# 仅用于本机私人使用；不要把 vendor/ 下的运行时提交到公开仓库。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/yingxia-java-host"
HOST="$DEST/JavaHost"
VERSION="${YINGXIA_VERSION:-1.7.5}"

case "$(uname -m)" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="x86_64" ;;
  *) echo "不支持的 CPU 架构: $(uname -m)" >&2; exit 1 ;;
esac

if [ -x "$HOST/jre/bin/java" ] && [ -f "$HOST/host.jar" ] && [ "${1:-}" != "--force" ]; then
  echo "JavaHost 已存在: $HOST"
  echo "如需重新提取，运行: $0 --force"
  exit 0
fi

mkdir -p "$DEST"
DMG="$DEST/Yingxia-$VERSION-$ARCH.dmg"
URL="https://download.getmegaportal.com/yingxia/$VERSION/Yingxia-$VERSION-macos-$ARCH.dmg"

if [ ! -f "$DMG" ]; then
  echo "下载 Yingxia $VERSION ($ARCH)..."
  curl -fL --retry 3 --progress-bar -o "$DMG.tmp" "$URL"
  mv "$DMG.tmp" "$DMG"
fi

MOUNT="$(mktemp -d /tmp/yingxia-runtime.XXXXXX)"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "挂载 DMG..."
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" >/dev/null

SRC="$MOUNT/Yingxia.app/Contents/Resources/JavaHost"
if [ ! -f "$SRC/host.jar" ] || [ ! -x "$SRC/jre/bin/java" ]; then
  echo "DMG 中没有找到完整的 JavaHost" >&2
  exit 1
fi

echo "提取 JavaHost..."
rm -rf "$HOST"
ditto "$SRC" "$HOST"
touch "$HOST/.gitkeep"
chmod +x "$HOST/jre/bin/java" 2>/dev/null || true

echo "验证 JRE:"
"$HOST/jre/bin/java" -version

cat > "$DEST/NOTICE.md" <<EOF
# Yingxia JavaHost

来源: https://github.com/jo32/tvbox-silicon
版本: $VERSION ($ARCH)
许可证: GPL-3.0-only；其中包含 Unicorn 等第三方组件，详见 JavaHost/jre/legal 与上游仓库。

本目录仅用于本机私人自用。若分发包含该运行时的 App，请按 GPL-3.0 提供对应源码和许可证。
EOF

echo "完成: $HOST"
