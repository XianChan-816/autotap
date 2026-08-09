#!/bin/bash
# tools/fix-deb-arch.sh
#
# ############################################################################
# ##  ⛔ 已弃用 —— 不要再用这个脚本产出的 deb 去 dpkg -i 装机 ⛔              ##
# ##                                                                        ##
# ##  2026-08-09 事故定案：手工 dpkg-deb -R / -b 重打的包会把 ellekit 的      ##
# ##  /var/jb/Library/MobileSubstrate/DynamicLibraries（本体是 symlink →     ##
# ##  /usr/lib/TweakInject）替换成真实目录，ellekit 的 injection_init 目录    ##
# ##  自检失败 → abort → 全机每个 App 一起来就 SIGABRT。                      ##
# ##  救援：sudo apt-get install --reinstall -y --allow-unauthenticated      ##
# ##       ellekit                                                          ##
# ##                                                                        ##
# ##  正确部署姿势：scp dylib/plist 到真实目录 /var/jb/usr/lib/TweakInject/   ##
# ##  + ldid -S 重签（见 ssh_deploy_v29.py，几十次部署零事故）。              ##
# ##  另：Architecture arm64 vs arm64e 并不是 iU 的原因，别为改架构动 deb。   ##
# ############################################################################
#
# 以下逻辑仅保留作参考。脚本已内置硬拦截：一旦发现包里含会覆盖 ellekit
# symlink 的目录条目，直接 exit 1 拒绝出包。
#
# 修两个坑（都实际炸过）：
#
# 【坑 1】Architecture 被 theos 强制改回 iphoneos-arm64
#   Dopamine roothide theos 的 vendor/mod/rootless/package/deb.mk 写死：
#       ifneq ($(THEOS_PACKAGE_ARCH),iphoneos-arm64)
#           THEOS_PACKAGE_ARCH := iphoneos-arm64
#   无论 control 写什么都被覆盖。dpkg 会把 :iphoneos-arm64 和 :iphoneos-arm64e
#   当成两个独立包，旧的 iU 残骸永远 purge 不掉 → Sileo 一直报依赖错。
#
# 【坑 2】属主被记成构建机用户（2026-08-09 事故：全机 App 打不开）
#   在 Linux 上非 root 跑 dpkg-deb -b，tar 里的 uid/gid 记成构建者（WSL 是 1000）。
#   dpkg -i 会照着还原 → /var/jb/Library/MobileSubstrate 整棵树变 mobile 所有。
#   Dopamine 的注入器检查到该目录不是 root 所有 → 判定被篡改 →
#   每个新起的 App 进程都加载失败 → 除了已在跑的 SpringBoard，App 全打不开。
#   必须强制 root:root(0:0)。
#
# 用法： ./tools/fix-deb-arch.sh packages/*.deb

set -e

if [ "$#" -lt 1 ]; then
    echo "用法: $0 <packages/*.deb> [more debs...]"
    exit 1
fi

# dpkg-deb >= 1.19 才有 --root-owner-group
ROOTOWN=""
if dpkg-deb --help 2>&1 | grep -q -- '--root-owner-group'; then
    ROOTOWN="--root-owner-group"
else
    echo "⚠️  dpkg-deb 不支持 --root-owner-group，将尝试 fakeroot"
fi

for DEB in "$@"; do
    [ -f "$DEB" ] || { echo "❌ 找不到 $DEB"; continue; }
    WORK=$(mktemp -d)
    echo "=== [fix-deb-arch] $DEB"

    dpkg-deb -R "$DEB" "$WORK/extract" >/dev/null

    # 坑 1：Architecture -> iphoneos-arm64e
    sed -i 's/^Architecture:.*$/Architecture: iphoneos-arm64e/' "$WORK/extract/DEBIAN/control"

    # 权限规范：目录 755 / control 644 / dylib 755 / plist 644 / 维护脚本 755
    find "$WORK/extract" -type d -exec chmod 755 {} +
    chmod 644 "$WORK/extract/DEBIAN/control"
    find "$WORK/extract" -name '*.dylib' -exec chmod 755 {} + 2>/dev/null || true
    find "$WORK/extract" -name '*.plist' -exec chmod 644 {} + 2>/dev/null || true
    for s in preinst postinst prerm postrm; do
        [ -f "$WORK/extract/DEBIAN/$s" ] && chmod 755 "$WORK/extract/DEBIAN/$s"
    done

    ARCH=$(grep '^Architecture:' "$WORK/extract/DEBIAN/control")
    rm -f "$DEB"

    # 坑 2：强制 root:root 属主
    if [ -n "$ROOTOWN" ]; then
        dpkg-deb $ROOTOWN -b "$WORK/extract" "$DEB" >/dev/null
    elif command -v fakeroot >/dev/null 2>&1; then
        fakeroot sh -c "chown -R 0:0 '$WORK/extract' && dpkg-deb -b '$WORK/extract' '$DEB'" >/dev/null
    else
        echo "❌ 既无 --root-owner-group 也无 fakeroot，属主会被污染，中止"
        rm -rf "$WORK"
        exit 1
    fi

    # 校验：tar 里必须全是 root/root（或 0/0）
    BAD=$(dpkg-deb --ctrl-tarfile "$DEB" 2>/dev/null | tar tvf - 2>/dev/null | awk '{print $2}' | grep -v '^root/root$\|^0/0$' | head -3 || true)
    BAD2=$(dpkg-deb --fsys-tarfile "$DEB" 2>/dev/null | tar tvf - 2>/dev/null | awk '{print $2}' | grep -v '^root/root$\|^0/0$' | head -3 || true)
    rm -rf "$WORK"

    echo "  -> $ARCH"
    if [ -n "$BAD$BAD2" ]; then
        echo "  ❌ 属主校验失败，仍存在非 root 条目：$BAD $BAD2"
        exit 1
    fi
    echo "  -> 属主校验 OK (全部 root/root)"

    # ==== 硬拦截：包里不许含会覆盖 ellekit symlink 的目录条目 ====
    # ellekit 把 /var/jb/Library/MobileSubstrate/DynamicLibraries 做成
    # symlink -> /usr/lib/TweakInject。deb 里若含它的「目录条目」，
    # dpkg -i 会把 symlink 替换成真目录 → ellekit injection_init 自检失败
    # → 全机每个 App SIGABRT（2026-08-09 事故）。
    KILLER=$(dpkg-deb --fsys-tarfile "$DEB" 2>/dev/null | tar tvf - 2>/dev/null \
             | awk '$1 ~ /^d/ {print $NF}' \
             | grep -E '(^|/)var/jb/Library/MobileSubstrate/DynamicLibraries/?$' || true)
    if [ -n "$KILLER" ]; then
        echo "  ⛔ 危险：包内含会覆盖 ellekit symlink 的目录条目："
        echo "     $KILLER"
        echo "     dpkg -i 会毁掉 DynamicLibraries -> /usr/lib/TweakInject，"
        echo "     导致全机 App 打不开。拒绝出包。"
        echo "     请改用 scp 部署到 /var/jb/usr/lib/TweakInject/（见 ssh_deploy_v29.py）。"
        exit 1
    fi
    echo "  -> ellekit symlink 安全校验 OK"
done

echo
echo "⚠️ 仍然不建议 dpkg -i 安装自打包，优先 scp 到 /var/jb/usr/lib/TweakInject/"
echo "   若装完 App 全打不开，救援："
echo "   sudo apt-get install --reinstall -y --allow-unauthenticated ellekit"
echo "   sudo chown -R root:wheel /var/jb/Library/MobileSubstrate"
