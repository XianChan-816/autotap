#!/bin/bash
# 一键清掉 iU 残骸 + 装 v2.9 deb
# ⚠️ 需 root —— 双击 mobile SSH 会话里跑，输入 sudo 密码

set -e

DEB_NEW="/tmp/com.floatingtap.tweak_2.9.0-coexist_arm64e.deb"

# 0. 确认存在
if [ ! -f "$DEB_NEW" ]; then
    echo "❌ 找不到 $DEB_NEW"
    exit 1
fi

# 1. 看现状（白说不练）
echo "=== [1/5] 当前 dpkg 状态 ==="
dpkg -l | grep -i floatingtap || echo "  (无残留)"
echo

# 2. 先把 iU 残骸彻底清除（purge = remove + remove config）
echo "=== [2/5] sudo purge 旧 iU 残骸 ==="
# 旧包名是 :iphoneos-arm64（v2.8.12 控制文件写错了 Arch：没用 64e）
# 这个 iU 状态下 dpkg --purge 有 50% 概率自动成功，剩下情况需 --force-remove-reinstreq
sudo dpkg --purge com.floatingtap.tweak:iphoneos-arm64 2>&1 | tail -5 \
   || sudo dpkg --purge --force-remove-reinstreq com.floatingtap.tweak:iphoneos-arm64 2>&1 | tail -5 \
   || true
echo

# 3. 手动 dpkg -i 安装新 deb（绕过 sileo，配置走 dpkg 直接安装）
echo "=== [3/5] sudo dpkg -i 安装新 deb（架构 iphoneos-arm64e） ==="
sudo dpkg -i "$DEB_NEW" 2>&1 | tail -15
echo

# 4. 触发 apt 解决可能残余依赖
echo "=== [4/5] sudo apt-get install -f（修任何悬空依赖） ==="
sudo apt-get install -fy 2>&1 | tail -10
echo

# 5. 验证状态
echo "=== [5/5] 验证 ==="
dpkg -l | grep -i floatingtap
echo
dpkg -s com.floatingtap.tweak | head -8
echo
echo "⚠️  关电脑：手动打开 Dopamine App → Userspace Reboot"
echo "    跑回来再说一声，我 ssh_verify_v29.py 看效果"
