#!/bin/sh
# 从 openhongguo v0.1.1 源码编译 OpenhongguoCore.xcframework，放到 Vendor/Openhongguo/。
# 需要：Xcode、Go 1.26+、gomobile（go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init）。
# 上游 Release 没有发布 xcframework，所以需要这一步；产物已存在时直接跳过。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/Vendor/Openhongguo/OpenhongguoCore.xcframework"
[ -d "$dest" ] && { echo "已存在：$dest"; exit 0; }
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"; export DEVELOPER_DIR
export PATH="$HOME/.local/go/bin:$HOME/go/bin:$PATH"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone --depth 1 --branch v0.1.1 https://github.com/beilunyang/openhongguo.git "$work/openhongguo"
(cd "$work/openhongguo/bindings/mobile" && ./build.sh ios)
cp -R "$work/openhongguo/bindings/mobile/build/OpenhongguoCore.xcframework" "$dest"
echo "完成：$dest"
