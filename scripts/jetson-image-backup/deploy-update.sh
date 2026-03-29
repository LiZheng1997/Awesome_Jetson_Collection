#!/bin/bash
# ============================================================
# Jetson Orin 远程增量更新脚本
# 适用场景：已部署的设备需要迭代更新（不需要重新刷机）
#
# 工作原理：
#   通过 rsync over SSH 将"黄金镜像机"的 rootfs 增量同步到目标设备
#   只传输有变化的文件，速度远快于全量备份恢复
#
# 用法：
#   ./deploy-update.sh <目标设备IP> [SSH用户名]
#   例：./deploy-update.sh 192.168.8.10
#       ./deploy-update.sh 192.168.8.10 lz
#
# 注意：
#   - 在"黄金镜像机"上运行，将本机系统同步到目标设备
#   - 目标设备必须与本机型号相同
#   - 更新完成后目标设备需要重启生效
# ============================================================

set -euo pipefail

# -------------------- 配置 --------------------
# 不需要同步的目录（设备特定配置、临时文件等）
RSYNC_EXCLUDES=(
    "/dev/*"
    "/proc/*"
    "/sys/*"
    "/tmp/*"
    "/run/*"
    "/mnt/*"
    "/media/*"
    "/lost+found"
    "/snap/*"
    "/swapfile"
    "/var/cache/apt/archives/*.deb"
    "/var/log/*"
    "/home/*/.cache/*"
    "/home/*/.local/share/Trash/*"
    # 设备特定文件（不应被覆盖）
    "/etc/hostname"
    "/etc/machine-id"
    "/etc/ssh/ssh_host_*"
    "/etc/NetworkManager/system-connections/*"
)

# -------------------- 参数检查 --------------------
if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 sudo 运行此脚本。"
    echo "用法：sudo $0 <目标设备IP> [SSH用户名]"
    exit 1
fi

if [ -z "${1:-}" ]; then
    echo "错误：请指定目标设备 IP 地址。"
    echo "用法：sudo $0 <目标设备IP> [SSH用户名]"
    exit 1
fi

TARGET_IP="$1"
TARGET_USER="${2:-lz}"

echo ""
echo "============================================================"
echo "  Jetson 远程增量更新"
echo "============================================================"
echo ""
echo "  源设备（本机）：$(hostname) / $(hostname -I | awk '{print $1}')"
echo "  目标设备：${TARGET_USER}@${TARGET_IP}"
echo ""

# 测试 SSH 连通性
echo "测试 SSH 连接..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${TARGET_USER}@${TARGET_IP}" "echo ok" >/dev/null 2>&1; then
    echo "错误：无法通过 SSH 连接到 ${TARGET_USER}@${TARGET_IP}"
    echo "请确认："
    echo "  1. 目标设备已开机且网络可达"
    echo "  2. SSH 服务已启动"
    echo "  3. 已配置 SSH 密钥免密登录（推荐）"
    exit 1
fi
echo "  连接成功。"

# 预览变化
echo ""
echo "正在扫描差异（dry-run）..."

EXCLUDE_ARGS=()
for excl in "${RSYNC_EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$excl")
done

# dry-run 统计变化量
CHANGES=$(rsync -aAXH --dry-run --stats \
    "${EXCLUDE_ARGS[@]}" \
    -e ssh \
    / "${TARGET_USER}@${TARGET_IP}:/" 2>&1 | tail -15)

echo "$CHANGES"
echo ""
read -p "确认推送更新到 ${TARGET_IP}？[y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 1

# 执行同步
echo ""
echo "正在同步（增量传输）..."

rsync -aAXH --info=progress2 \
    "${EXCLUDE_ARGS[@]}" \
    -e ssh \
    / "${TARGET_USER}@${TARGET_IP}:/"

echo ""
echo "============================================================"
echo "  更新完成！"
echo "============================================================"
echo ""
echo "  目标设备需要重启以使更新生效："
echo "    ssh ${TARGET_USER}@${TARGET_IP} 'sudo reboot'"
echo ""
echo "  已排除的设备特定文件（不会被覆盖）："
echo "    - /etc/hostname（主机名）"
echo "    - /etc/machine-id（设备唯一 ID）"
echo "    - /etc/ssh/ssh_host_*（SSH 主机密钥）"
echo "    - /etc/NetworkManager/（网络配置）"
echo "============================================================"
