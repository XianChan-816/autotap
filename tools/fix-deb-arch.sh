// tools/fix-deb-arch.sh
// 修 Dopamine roothide theos 强制覆盖 Architecture 为 iphoneos-arm64 的坑。
// theos 的 vendor/mod/rootless/package/deb.mk 写死了"非 arm64 就改成 arm64"，
// 我们要让包名后缀是 iphoneos-arm64e，否则 dpkg 把新包当独立条目，
// 旧的 iU 残骸永远无法被覆盖 → sileo 一直报"ellemkit"、依赖永远 unconfigured。
//
// 用法：theos 打完之后，跑 ./tools/fix-deb-arch.sh packages/*.deb
// 会把 deb 里的 DEBIAN/control 的 Architecture 字段改为 iphoneos-arm64e，
// 然后 dpkg-deb -b 重打。

#!/bin/bash
set -e

if [ "$#" -lt 1 ]; then
    echo "用法: $0 <packages/*.deb> [more debs...]"
    exit 1
fi

for DEB in "$@"; do
    [ -f "$DEB" ] || { echo "❌ 找不到 $DEB"; continue; }
    WORK=$(mktemp -d)
    echo "=== [fix-deb-arch] $DEB ==="
    dpkg-deb -R "$DEB" "$WORK/extract" >/dev/null
    sed -i 's/^Architecture:.*$/Architecture: iphoneos-arm64e/' "$WORK/extract/DEBIAN/control"
    chmod 755 "$WORK/extract/DEBIAN"
    chmod 644 "$WORK/extract/DEBIAN/control"
    ARCH=$(grep '^Architecture:' "$WORK/extract/DEBIAN/control")
    rm -f "$DEB"
    dpkg-deb -b "$WORK/extract" "$DEB" >/dev/null
    rm -rf "$WORK"
    echo "  -> $ARCH"
    dpkg-deb -f "$DEB" Package | head -2
done

echo
echo "完成。"
