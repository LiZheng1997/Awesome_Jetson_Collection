#!/bin/bash
# ============================================================
# 修复 Jetson 平台上误装桌面版 NVIDIA 驱动导致的依赖冲突脚本
# 问题原因：Autoware 的 env_setup 脚本安装了桌面版 NVIDIA 驱动
#          （595.58.03），与 Jetson 自带的 L4T 驱动产生文件冲突
# ============================================================

# 遇到错误时停止执行（除了我们用 || true 显式忽略的命令）
set -e

echo "=== 第1步：强制卸载桌面版 NVIDIA 驱动包 ==="
# 使用 dpkg 强制移除，因为 apt 已经陷入依赖死循环无法正常操作
# --force-remove-reinstreq：允许移除处于"需要重新安装"状态的包
# --force-depends：忽略依赖关系强制移除
# || true：即使部分包不存在也继续执行，不中断脚本
sudo dpkg --remove --force-remove-reinstreq --force-depends \
  nvidia-driver-open \
  nvidia-open \
  nvidia-dkms-open \
  nvidia-kernel-source-open \
  nvidia-kernel-common \
  nvidia-firmware \
  nvidia-modprobe \
  nvidia-persistenced \
  nvidia-settings \
  libnvidia-cfg1 \
  libnvidia-common \
  libnvidia-decode \
  libnvidia-encode \
  libnvidia-fbc1 \
  libnvidia-gpucomp \
  libnvidia-compute \
  libnvidia-gl \
  libxnvctrl0 \
  xserver-xorg-video-nvidia \
  screen-resolution-extra \
  dkms 2>&1 || true

echo ""
echo "=== 第2步：修复残留的依赖问题 ==="
# 让 apt 自动处理第1步强制卸载后可能遗留的依赖问题
sudo apt --fix-broken install -y

echo ""
echo "=== 第3步：清理不再需要的依赖包 ==="
# 移除那些作为依赖自动安装、但现在已无包依赖它们的孤立包
sudo apt autoremove -y

echo ""
echo "=== 第4步：处理未完成的 dpkg 触发器 ==="
# dpkg --audit 中显示有多个包触发了 trigger 但未处理，这里统一处理
sudo dpkg --configure --pending

echo ""
echo "=== 第5步：验证 Jetson L4T 原生驱动是否完好 ==="
# 确认 nvidia-l4t-* 包仍然正常安装，这些是 Jetson 正常运行所必需的
echo "已安装的 nvidia-l4t 包："
dpkg -l | grep nvidia-l4t || echo "警告：未找到任何 nvidia-l4t 包！"

echo ""
echo "=== 第6步：检查是否存在桌面版 NVIDIA 软件源 ==="
# 检查是否有指向桌面版 NVIDIA 驱动仓库的 apt 源文件
# 如果存在，需要手动删除，否则下次 apt upgrade 还会拉取桌面版驱动
echo "sources.list.d 中与 nvidia 相关的文件："
ls /etc/apt/sources.list.d/ 2>/dev/null | grep -i nvidia || echo "  （未找到）"
echo ""
echo "sources.list 中与 nvidia 相关的行："
grep -i nvidia /etc/apt/sources.list 2>/dev/null || echo "  （未找到）"

echo ""
echo "=== 第7步：锁定 L4T 包优先级，防止再次被桌面版覆盖 ==="
# 创建 apt pin 配置，将 L4T 包的优先级设为 1001（最高）
# 这样即使 apt 源中有更新版本的桌面版驱动，也不会替换 L4T 版本
sudo tee /etc/apt/preferences.d/nvidia-l4t-pin > /dev/null <<'EOF'
Package: nvidia-l4t-*
Pin: origin ""
Pin-Priority: 1001
EOF
echo "锁定配置已写入 /etc/apt/preferences.d/nvidia-l4t-pin"

echo ""
echo "=== 完成！==="
echo "如果第6步发现了桌面版 NVIDIA 的 .list 源文件，请手动删除："
echo "  sudo rm /etc/apt/sources.list.d/<文件名>"
