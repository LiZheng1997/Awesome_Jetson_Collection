#!/bin/bash
# ============================================================
# Jetson Orin NVMe 系统镜像备份脚本
# 适用平台：Jetson AGX Orin / Orin NX / Orin Nano (NVMe SSD 启动)
# 适用系统：JetPack 6.x (L4T 36.x)
#
# 功能：
#   - 备份 GPT 分区表
#   - rsync 备份 rootfs（APP 分区）
#   - dd 备份非 rootfs 分区（kernel、DTB、ESP、recovery 等）
#   - 打包为一个可分发的压缩包
#
# 用法：
#   sudo ./backup.sh [备份输出目录]
#   例：sudo ./backup.sh /media/lz/usb-drive/jetson-backups
#
# 输出：
#   <输出目录>/jetson-image-YYYYMMDD-HHMMSS.tar.gz
# ============================================================

set -euo pipefail

# -------------------- 配置 --------------------
NVME_DEV="/dev/nvme0n1"         # NVMe 设备路径
APP_PART="${NVME_DEV}p1"        # rootfs 分区 (APP)
# 非 rootfs 分区编号（kernel A/B、DTB、ESP、recovery 等）
NON_APP_PARTS=(2 3 4 5 6 7 8 9 10 11 12 13 14 15)

# rsync 排除目录（虚拟文件系统、临时文件、挂载点）
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
    "/var/log/*.gz"
    "/var/log/*.old"
    "/var/log/journal/*"
    "/home/*/.cache/*"
    "/home/*/.local/share/Trash/*"
)

# -------------------- 参数检查 --------------------
if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 sudo 运行此脚本。"
    echo "用法：sudo $0 [备份输出目录]"
    exit 1
fi

BACKUP_BASE="${1:-/tmp/jetson-backup}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_BASE}/jetson-image-${TIMESTAMP}"

# 检查 NVMe 设备是否存在
if [ ! -b "$NVME_DEV" ]; then
    echo "错误：未找到 NVMe 设备 $NVME_DEV"
    exit 1
fi

# 检查输出目录剩余空间（至少需要已用空间大小）
USED_KB=$(df --output=used / | tail -1 | tr -d ' ')
USED_GB=$((USED_KB / 1024 / 1024))
echo "当前 rootfs 已用空间约 ${USED_GB}GB"

if [ -n "${1:-}" ]; then
    mkdir -p "$BACKUP_BASE"
    AVAIL_KB=$(df --output=avail "$BACKUP_BASE" | tail -1 | tr -d ' ')
    AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
    echo "输出目录可用空间约 ${AVAIL_GB}GB"
    if [ "$AVAIL_KB" -lt "$USED_KB" ]; then
        echo "警告：可用空间可能不足（需要约 ${USED_GB}GB，可用 ${AVAIL_GB}GB）。"
        read -p "是否继续？[y/N] " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    fi
fi

mkdir -p "$BACKUP_DIR"
echo ""
echo "============================================================"
echo "  Jetson NVMe 系统镜像备份"
echo "  输出目录：$BACKUP_DIR"
echo "  时间：$(date)"
echo "============================================================"
echo ""

# -------------------- 第1步：备份系统信息 --------------------
echo "[1/4] 记录系统信息..."

{
    echo "=== 备份时间 ==="
    date
    echo ""
    echo "=== L4T 版本 ==="
    cat /etc/nv_tegra_release 2>/dev/null || echo "未找到"
    echo ""
    echo "=== JetPack / CUDA 版本 ==="
    dpkg -l | grep -E "nvidia-l4t-core|cuda-toolkit" | head -5
    echo ""
    echo "=== 内核版本 ==="
    uname -r
    echo ""
    echo "=== NVMe 分区表 ==="
    fdisk -l "$NVME_DEV"
    echo ""
    echo "=== 已安装包列表 ==="
    dpkg --get-selections
} > "$BACKUP_DIR/system-info.txt" 2>&1

echo "  完成。"

# -------------------- 第2步：备份 GPT 分区表 --------------------
echo ""
echo "[2/4] 备份 GPT 分区表..."

sgdisk --backup="$BACKUP_DIR/nvme-partition-table.gpt" "$NVME_DEV"

echo "  完成。"

# -------------------- 第3步：rsync 备份 rootfs --------------------
echo ""
echo "[3/4] 备份 rootfs（这一步耗时较长）..."

ROOTFS_DIR="$BACKUP_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# 构建 rsync 排除参数
EXCLUDE_ARGS=()
for excl in "${RSYNC_EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$excl")
done

rsync -aAXH --info=progress2 \
    "${EXCLUDE_ARGS[@]}" \
    / "$ROOTFS_DIR/"

echo "  完成。"

# -------------------- 第4步：dd 备份非 APP 分区 --------------------
echo ""
echo "[4/4] 备份非 rootfs 分区（kernel、DTB、ESP、recovery）..."

PARTS_DIR="$BACKUP_DIR/partitions"
mkdir -p "$PARTS_DIR"

for p in "${NON_APP_PARTS[@]}"; do
    PART_DEV="${NVME_DEV}p${p}"
    if [ -b "$PART_DEV" ]; then
        # 获取分区标签
        PART_LABEL=$(blkid -s PARTLABEL -o value "$PART_DEV" 2>/dev/null || echo "unknown")
        echo "  备份 p${p} (${PART_LABEL})..."
        dd if="$PART_DEV" of="$PARTS_DIR/p${p}_${PART_LABEL}.img" bs=4M status=none
    fi
done

echo "  完成。"

# -------------------- 打包压缩 --------------------
echo ""
echo "正在打包压缩（这一步耗时较长）..."

ARCHIVE_NAME="jetson-image-${TIMESTAMP}.tar.gz"
tar -czf "$BACKUP_BASE/$ARCHIVE_NAME" -C "$BACKUP_BASE" "jetson-image-${TIMESTAMP}"

# 计算压缩包大小
ARCHIVE_SIZE=$(du -h "$BACKUP_BASE/$ARCHIVE_NAME" | cut -f1)

# 清理未压缩的目录
rm -rf "$BACKUP_DIR"

echo ""
echo "============================================================"
echo "  备份完成！"
echo "  压缩包：$BACKUP_BASE/$ARCHIVE_NAME"
echo "  大小：$ARCHIVE_SIZE"
echo "============================================================"
echo ""
echo "  恢复到新设备时："
echo "  1. 先用 SDK Manager 或 flash.sh 刷写 QSPI 引导分区"
echo "  2. 再运行 restore.sh 恢复 NVMe 内容"
echo "============================================================"
