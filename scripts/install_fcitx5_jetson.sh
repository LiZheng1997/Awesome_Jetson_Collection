#!/bin/bash
# ============================================================
# Jetson 嵌入式平台 fcitx5 中文输入法安装脚本
# 适用平台：NVIDIA Jetson Orin / Xavier 等 (aarch64)
# 适用系统：Ubuntu 22.04 (Jammy) with JetPack
# ============================================================

set -e

echo "============================================================"
echo "  Jetson 平台 fcitx5 中文输入法安装脚本"
echo "============================================================"
echo ""

# 不要以 root 运行，im-config 需要写入当前用户的 ~/.xinputrc
if [ "$EUID" -eq 0 ]; then
    echo "错误：请不要使用 sudo 运行此脚本，脚本内部会在需要时自动请求 sudo 权限。"
    echo "用法：./install_fcitx5_jetson.sh"
    exit 1
fi

# 检查是否为 aarch64 平台
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "警告：当前平台为 $ARCH，此脚本专为 Jetson (aarch64) 设计。"
    read -p "是否继续？[y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

# ----------------------------------------------------------
# 第1步：卸载可能冲突的旧版输入法
# JetPack 默认安装 iBus，如有手动安装 fcitx4/搜狗也一并清理
# ----------------------------------------------------------
echo "[1/5] 检测并卸载冲突的输入法..."

# 检测 iBus（JetPack 默认输入法框架）
# iBus 和 fcitx5 可以共存，但同时存在可能偶尔产生冲突，由用户决定是否卸载
if dpkg -l ibus 2>/dev/null | grep -q "^ii"; then
    echo "  检测到 iBus（JetPack 默认输入法框架）。"
    echo "  iBus 与 fcitx5 可以共存，但卸载 iBus 可避免潜在冲突。"
    read -p "  是否卸载 iBus？[y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo apt remove --purge -y ibus 'ibus-*' 2>/dev/null || true
        echo "  iBus 已卸载。"
    else
        echo "  保留 iBus，跳过。"
    fi
else
    echo "  未检测到 iBus，跳过。"
fi

# 检测并卸载 fcitx4（可能由第三方脚本如 Autoware env_setup 安装）
# 注意：使用精确包名匹配，避免通配符 fcitx-* 误删 fcitx5 的包
if dpkg -l fcitx 2>/dev/null | grep -q "^ii"; then
    echo "  检测到 fcitx4，正在卸载..."
    FCITX4_PKGS=$(dpkg -l | grep "^ii" | awk '{print $2}' | grep -E "^fcitx($|[^5])" || true)
    if [ -n "$FCITX4_PKGS" ]; then
        sudo apt remove --purge -y $FCITX4_PKGS 2>/dev/null || true
    fi
else
    echo "  未检测到 fcitx4，跳过。"
fi

# 检测并卸载搜狗拼音（可能由用户手动安装，且在 Jetson 上不稳定）
if dpkg -l sogoupinyin 2>/dev/null | grep -q "^ii\|^iU"; then
    echo "  检测到搜狗拼音，正在卸载（搜狗在 Jetson arm64 上存在崩溃问题）..."
    sudo dpkg --remove --force-remove-reinstreq sogoupinyin 2>/dev/null || true
else
    echo "  未检测到搜狗拼音，跳过。"
fi

sudo apt autoremove -y 2>/dev/null || true
echo "  完成。"

# ----------------------------------------------------------
# 第2步：更新软件包索引
# ----------------------------------------------------------
echo ""
echo "[2/5] 更新软件包索引..."
sudo apt update || echo "  警告：apt update 部分失败，继续安装..."
echo "  完成。"

# ----------------------------------------------------------
# 第3步：安装中文字体
# ----------------------------------------------------------
echo ""
echo "[3/5] 安装中文字体..."
sudo apt install -y fonts-wqy-microhei fonts-wqy-zenhei
echo "  完成。"

# ----------------------------------------------------------
# 第4步：安装 fcitx5 及中文输入法组件
# ----------------------------------------------------------
echo ""
echo "[4/5] 安装 fcitx5 及中文输入法组件..."
# fcitx5                    - 输入法框架核心
# fcitx5-chinese-addons     - 中文拼音、五笔等输入法引擎
# fcitx5-frontend-gtk2/3    - GTK 应用输入法支持
# fcitx5-frontend-qt5       - Qt5 应用输入法支持
# fcitx5-module-cloudpinyin - 云拼音，提升候选词质量
# fcitx5-config-qt          - 图形化配置工具
sudo apt install -y \
    fcitx5 \
    fcitx5-chinese-addons \
    fcitx5-frontend-gtk2 \
    fcitx5-frontend-gtk3 \
    fcitx5-frontend-qt5 \
    fcitx5-module-cloudpinyin \
    fcitx5-config-qt
echo "  完成。"

# ----------------------------------------------------------
# 第5步：设置 fcitx5 为默认输入法框架
# im-config 会自动将环境变量（GTK_IM_MODULE、QT_IM_MODULE、
# XMODIFIERS）写入 ~/.xinputrc，图形登录时由系统自动加载，
# 无需手动修改 ~/.xprofile 或 ~/.bashrc
# ----------------------------------------------------------
echo ""
echo "[5/5] 配置 fcitx5 为默认输入法框架..."
im-config -n fcitx5
echo "  完成。"

echo ""
echo "============================================================"
echo "  安装完成！请按以下步骤完成配置："
echo "============================================================"
echo ""
echo "  1. 重启系统："
echo "       sudo reboot"
echo ""
echo "  2. 重启后打开输入法配置工具："
echo "       fcitx5-configtool"
echo ""
echo "  3. 在配置界面中："
echo "       - 点击左下角 '+' 添加输入法"
echo "       - 取消勾选 'Only Show Current Language'（仅显示当前语言）"
echo "       - 搜索 'Pinyin'，选择添加"
echo ""
echo "  4. 使用 Ctrl+Space 切换中英文输入法"
echo ""
echo "  提示：云拼音已安装，可在 fcitx5-configtool 的"
echo "        Addons -> Cloud Pinyin 中配置，提升候选词质量。"
echo ""
echo "  注意：如果重启后部分应用无法使用输入法，可手动添加"
echo "        以下内容到 ~/.xprofile："
echo "          export GTK_IM_MODULE=fcitx"
echo "          export QT_IM_MODULE=fcitx"
echo "          export XMODIFIERS=@im=fcitx"
echo "============================================================"
