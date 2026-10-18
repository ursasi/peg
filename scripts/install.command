#!/bin/bash
# Double-click this after unzipping. macOS marks downloads as quarantined and
# refuses to launch an app that is not notarised — it calls it "damaged", which
# is misleading: the file is fine, Gatekeeper just will not run it.
set -e
cd "$(dirname "$0")"

SRC="Peg.app"
DEST="/Applications/Peg.app"

if [ ! -d "$SRC" ]; then
    echo "找不到 Peg.app，请把本脚本和 Peg.app 放在同一个文件夹里。"
    read -r -p "按回车退出。" _
    exit 1
fi

echo "正在退出 Peg…"
osascript -e 'quit app "Peg"' >/dev/null 2>&1 || true
sleep 1

echo "移除隔离属性（这一步让 macOS 允许运行本地构建的 app）…"
xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true
codesign --force --deep --sign - "$SRC" >/dev/null 2>&1 || true

echo "安装到 /Applications …"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "打开 Peg…"
open "$DEST"

cat <<'DONE'

完成。

第一次截图时 macOS 会请求「屏幕录制」权限：
  系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 Peg
勾选之后要退出并重新打开 Peg，系统才会把画面交给它。
DONE
read -r -p "按回车关闭这个窗口。" _
