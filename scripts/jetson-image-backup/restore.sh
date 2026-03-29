#!/bin/bash
# ============================================================
# Jetson Orin NVMe 系统镜像恢复脚本
# 适用平台：Jetson AGX Orin / Orin NX / Orin Nano (NVMe SSD 启动)
# 适用系统：JetPack 6.x (L4T 36.x)
#
# 前置条件：
#   1. 目标 Jetson 已通过 SDK Manager 或 flash.sh 刷写好 QSPI 引导分区
#   2. 目标 Jetson 从 USB/SD 卡或 eMMC 的临时系统启动
#   3. 新 NVMe SSD 已安装到设备上
#
# 用法：
#   sudo ./restore.sh <备份压缩包路径> [NVMe设备路径]
#   例：sudo ./restore.sh /media/lz/usb/jetson-image-20260329.tar.gz
#       sudo ./restore.sh /media/lz/usb/jetson-image-20260329.tar.gz /dev/nvme0n1
# ============================================================

set -euo pipefail

# -------------------- 参数检查 --------------------
if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 sudo 运行此脚本。"
    echo "用法：sudo $0 <备份压缩包路径> [NVMe设备路径]"
    exit 1
fi

if [ -z "${1:-}" ]; then
    echo "错误：请指定备份压缩包路径。"
    echo "用法：sudo $0 <备份压缩包路径> [NVMe设备路径]"
    exit 1
fi

ARCHIVE="$1"
NVME_DEV="${2:-/dev/nvme0n1}"
APP_PART="${NVME_DEV}p1"

if [ ! -f "$ARCHIVE" ]; then
    echo "错误：未找到备份文件 $ARCHIVE"
    exit 1
fi

if [ ! -b "$NVME_DEV" ]; then
    echo "错误：未找到 NVMe 设备 $NVME_DEV"
    exit 1
fi

# 安全检查：确保不是从目标 NVMe 启动的
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_DEV" == ${NVME_DEV}* ]]; then
    echo "错误：当前系统正从 $NVME_DEV 启动，不能恢复到正在使用的设备。"
    echo "请从 USB/SD 卡或 eMMC 的临时系统启动后再运行此脚本。"
    exit 1
fi

echo ""
echo "============================================================"
echo "  Jetson NVMe 系统镜像恢复"
echo "============================================================"
echo ""
echo "  备份文件：$ARCHIVE"
echo "  目标设备：$NVME_DEV"
echo ""
echo "  警告：此操作将擦除 $NVME_DEV 上的所有数据！"
echo ""
read -p "确认继续？[y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 1

# -------------------- 解压备份 --------------------
echo ""
echo "[1/5] 解压备份文件..."

WORK_DIR=$(mktemp -d)
tar -xzf "$ARCHIVE" -C "$WORK_DIR"

# 找到解压后的目录（jetson-image-YYYYMMDD-HHMMSS）
BACKUP_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "jetson-image-*" | head -1)
if [ -z "$BACKUP_DIR" ]; then
    echo "错误：备份文件结构不正确，未找到 jetson-image-* 目录。"
    rm -rf "$WORK_DIR"
    exit 1
fi

echo "  完成。"

# -------------------- 恢复 GPT 分区表 --------------------
echo ""
echo "[2/5] 恢复 GPT 分区表..."

GPT_FILE="$BACKUP_DIR/nvme-partition-table.gpt"
if [ ! -f "$GPT_FILE" ]; then
    echo "错误：未找到分区表备份文件。"
    rm -rf "$WORK_DIR"
    exit 1
fi

# 清除现有分区表并恢复
sgdisk --zap-all "$NVME_DEV"
sgdisk --load-backup="$GPT_FILE" "$NVME_DEV"
# 生成新的磁盘 GUID，避免与源设备冲突
sgdisk -G "$NVME_DEV"
# 通知内核重新读取分区表
partprobe "$NVME_DEV"
sleep 2

echo "  完成。"

# -------------------- 格式化并恢复 rootfs --------------------
echo ""
echo "[3/5] 格式化 APP 分区并恢复 rootfs（这一步耗时较长）..."

mkfs.ext4 -F -L APP "$APP_PART"

MOUNT_POINT=$(mktemp -d)
mount "$APP_PART" "$MOUNT_POINT"

rsync -aAXH --info=progress2 "$BACKUP_DIR/rootfs/" "$MOUNT_POINT/"

echo "  完成。"

# -------------------- 恢复非 APP 分区 --------------------
echo ""
echo "[4/5] 恢复非 rootfs 分区（kernel、DTB、ESP、recovery）..."

PARTS_DIR="$BACKUP_DIR/partitions"
if [ -d "$PARTS_DIR" ]; then
    for img_file in "$PARTS_DIR"/p*_*.img; do
        if [ -f "$img_file" ]; then
            # 从文件名提取分区编号（格式：p2_A_kernel.img）
            PART_NUM=$(basename "$img_file" | sed 's/^p\([0-9]*\)_.*/\1/')
            PART_DEV="${NVME_DEV}p${PART_NUM}"
            PART_NAME=$(basename "$img_file" .img | sed 's/^p[0-9]*_//')
            if [ -b "$PART_DEV" ]; then
                echo "  恢复 p${PART_NUM} (${PART_NAME})..."
                dd if="$img_file" of="$PART_DEV" bs=4M status=none
            else
                echo "  警告：分区 $PART_DEV 不存在，跳过 $PART_NAME"
            fi
        fi
    done
else
    echo "  警告：未找到分区备份目录，跳过。"
fi

echo "  完成。"

# -------------------- 验证引导配置 --------------------
echo ""
echo "[5/5] 验证引导配置..."

# 检查 extlinux.conf
EXTLINUX="$MOUNT_POINT/boot/extlinux/extlinux.conf"
if [ -f "$EXTLINUX" ]; then
    echo "  extlinux.conf 中的 root 设备："
    grep -o "root=[^ ]*" "$EXTLINUX" | head -1
else
    echo "  警告：未找到 extlinux.conf"
fi

# 检查 fstab
echo "  fstab 中的挂载配置："
grep -v "^#" "$MOUNT_POINT/etc/fstab" | grep -v "^$" | head -5

# 检查 nv_boot_control.conf
if [ -f "$MOUNT_POINT/etc/nv_boot_control.conf" ]; then
    echo "  启动设备配置："
    grep "TEGRA_BOOT_STORAGE" "$MOUNT_POINT/etc/nv_boot_control.conf"
fi

# 卸载
sync
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

# 清理临时文件
rm -rf "$WORK_DIR"

echo ""
echo "============================================================"
echo "  恢复完成！"
echo "============================================================"
echo ""
echo "  请拔掉 USB/SD 卡启动盘，重启设备从 NVMe 启动："
echo "    sudo reboot"
echo ""
echo "  如果无法启动，可能需要重新刷写 QSPI 引导分区："
echo "    在 x86 主机上使用 SDK Manager 或 flash.sh 刷写 QSPI"
echo "============================================================"
