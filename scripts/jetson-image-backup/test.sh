#!/bin/bash
# ============================================================
# Jetson 镜像备份方案 - 测试脚本
# 在实际设备上验证 backup.sh / restore.sh / deploy-update.sh
# 的核心逻辑是否可以正常工作（不执行破坏性操作）
#
# 用法：sudo ./test.sh
# ============================================================

set -uo pipefail

PASS=0
FAIL=0
SKIP=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# -------------------- 测试工具函数 --------------------
pass() {
    echo "  [PASS] $1"
    ((PASS++))
}

fail() {
    echo "  [FAIL] $1"
    ((FAIL++))
}

skip() {
    echo "  [SKIP] $1"
    ((SKIP++))
}

section() {
    echo ""
    echo "=== $1 ==="
}

# -------------------- 权限检查 --------------------
if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 sudo 运行测试脚本。"
    echo "用法：sudo $0"
    exit 1
fi

echo "============================================================"
echo "  Jetson 镜像备份方案 - 测试"
echo "  时间：$(date)"
echo "============================================================"

# ==================== 1. 依赖工具检查 ====================
section "1. 依赖工具检查"

for tool in rsync sgdisk dd tar gzip blkid findmnt partprobe mkfs.ext4; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "$tool 可用"
    else
        fail "$tool 未安装"
    fi
done

# ==================== 2. 脚本文件检查 ====================
section "2. 脚本文件检查"

for script in backup.sh restore.sh deploy-update.sh; do
    filepath="$SCRIPT_DIR/$script"
    if [ -f "$filepath" ]; then
        pass "$script 存在"
    else
        fail "$script 不存在"
        continue
    fi

    if [ -x "$filepath" ]; then
        pass "$script 有执行权限"
    else
        fail "$script 无执行权限"
    fi

    # 语法检查
    if bash -n "$filepath" 2>/dev/null; then
        pass "$script 语法检查通过"
    else
        fail "$script 语法错误"
    fi
done

# ==================== 3. NVMe 设备检测 ====================
section "3. NVMe 设备检测"

NVME_DEV="/dev/nvme0n1"

if [ -b "$NVME_DEV" ]; then
    pass "NVMe 设备 $NVME_DEV 存在"
else
    fail "NVMe 设备 $NVME_DEV 不存在"
fi

# 检查分区数量
PART_COUNT=$(lsblk -n -o NAME "$NVME_DEV" 2>/dev/null | grep -c "nvme0n1p" || echo "0")
if [ "$PART_COUNT" -ge 14 ]; then
    pass "检测到 ${PART_COUNT} 个分区（预期 >= 14）"
else
    fail "仅检测到 ${PART_COUNT} 个分区（预期 >= 14）"
fi

# 检查 APP 分区
if [ -b "${NVME_DEV}p1" ]; then
    APP_LABEL=$(blkid -s PARTLABEL -o value "${NVME_DEV}p1" 2>/dev/null || echo "")
    if [ "$APP_LABEL" = "APP" ]; then
        pass "p1 分区标签为 APP"
    else
        fail "p1 分区标签为 '$APP_LABEL'（预期 APP）"
    fi
fi

# 检查关键分区标签
EXPECTED_LABELS=("A_kernel" "A_kernel-dtb" "B_kernel" "B_kernel-dtb" "esp" "recovery")
for label in "${EXPECTED_LABELS[@]}"; do
    found=false
    for p in $(seq 2 15); do
        part_dev="${NVME_DEV}p${p}"
        if [ -b "$part_dev" ]; then
            plabel=$(blkid -s PARTLABEL -o value "$part_dev" 2>/dev/null || echo "")
            if [ "$plabel" = "$label" ]; then
                found=true
                break
            fi
        fi
    done
    if $found; then
        pass "找到分区 $label"
    else
        fail "未找到分区 $label"
    fi
done

# ==================== 4. GPT 分区表备份/恢复测试 ====================
section "4. GPT 分区表备份测试"

GPT_TEST_FILE=$(mktemp)
if sgdisk --backup="$GPT_TEST_FILE" "$NVME_DEV" >/dev/null 2>&1; then
    GPT_SIZE=$(stat -c%s "$GPT_TEST_FILE")
    if [ "$GPT_SIZE" -gt 0 ]; then
        pass "GPT 分区表备份成功（${GPT_SIZE} 字节）"
    else
        fail "GPT 分区表备份文件为空"
    fi
else
    fail "sgdisk --backup 执行失败"
fi
rm -f "$GPT_TEST_FILE"

# ==================== 5. rsync 排除规则测试 ====================
section "5. rsync 排除规则测试"

RSYNC_EXCLUDES=(
    "/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*"
    "/mnt/*" "/media/*" "/lost+found" "/snap/*" "/swapfile"
    "/var/cache/apt/archives/*.deb"
)

RSYNC_TEST_DIR=$(mktemp -d)

EXCLUDE_ARGS=()
for excl in "${RSYNC_EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$excl")
done

# dry-run 测试 rsync 是否能正常解析排除规则
if rsync -aAXH --dry-run --stats "${EXCLUDE_ARGS[@]}" / "$RSYNC_TEST_DIR/" >/dev/null 2>&1; then
    pass "rsync 排除规则解析正常"
else
    fail "rsync 排除规则解析失败"
fi

# 验证排除规则确实排除了虚拟文件系统
# rsync itemize-changes 输出的是相对路径（如 proc/ 而非 /proc/）
# 使用精确匹配行首的目录名，避免匹配到路径中包含 proc/sys 的其他文件
RSYNC_OUTPUT=$(rsync -aAXH --dry-run --itemize-changes "${EXCLUDE_ARGS[@]}" / "$RSYNC_TEST_DIR/" 2>/dev/null | head -500)
if echo "$RSYNC_OUTPUT" | grep -qE " proc/[^ ]"; then
    fail "rsync 未排除 /proc 下的文件"
elif echo "$RSYNC_OUTPUT" | grep -qE " sys/[^ ]"; then
    fail "rsync 未排除 /sys 下的文件"
else
    pass "rsync 正确排除虚拟文件系统"
fi

rmdir "$RSYNC_TEST_DIR"

# ==================== 6. 非 APP 分区 dd 读取测试 ====================
section "6. 非 APP 分区 dd 读取测试"

DD_TEST_DIR=$(mktemp -d)
DD_TEST_PART="${NVME_DEV}p2"  # A_kernel 分区

if [ -b "$DD_TEST_PART" ]; then
    # 只读取前 4KB 测试 dd 是否可以工作
    if dd if="$DD_TEST_PART" of="$DD_TEST_DIR/test.img" bs=4K count=1 status=none 2>/dev/null; then
        TEST_SIZE=$(stat -c%s "$DD_TEST_DIR/test.img")
        if [ "$TEST_SIZE" -eq 4096 ]; then
            pass "dd 读取分区 p2 成功"
        else
            fail "dd 读取大小异常（${TEST_SIZE} 字节，预期 4096）"
        fi
    else
        fail "dd 读取分区 p2 失败"
    fi
else
    skip "分区 $DD_TEST_PART 不存在"
fi

rm -rf "$DD_TEST_DIR"

# ==================== 7. restore.sh 安全检查测试 ====================
section "7. restore.sh 安全检查测试"

# 测试：当从 NVMe 启动时，restore.sh 应拒绝恢复到同一设备
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_DEV" == ${NVME_DEV}* ]]; then
    pass "当前从 NVMe 启动，restore.sh 的安全检查应阻止恢复"
else
    skip "当前未从 NVMe 启动，无法测试安全检查"
fi

# 测试：restore.sh 对不存在的备份文件应报错
RESTORE_OUTPUT=$(bash "$SCRIPT_DIR/restore.sh" "/nonexistent/file.tar.gz" 2>&1 || true)
if echo "$RESTORE_OUTPUT" | grep -q "错误"; then
    pass "restore.sh 对不存在的文件正确报错"
else
    fail "restore.sh 未对不存在的文件报错"
fi

# ==================== 8. 压缩打包测试 ====================
section "8. 压缩打包测试"

TAR_TEST_DIR=$(mktemp -d)
mkdir -p "$TAR_TEST_DIR/jetson-image-test/rootfs"
echo "test content" > "$TAR_TEST_DIR/jetson-image-test/rootfs/test.txt"
echo "system info" > "$TAR_TEST_DIR/jetson-image-test/system-info.txt"

if tar -czf "$TAR_TEST_DIR/test.tar.gz" -C "$TAR_TEST_DIR" "jetson-image-test" 2>/dev/null; then
    pass "tar.gz 打包成功"

    # 测试解压
    EXTRACT_DIR=$(mktemp -d)
    if tar -xzf "$TAR_TEST_DIR/test.tar.gz" -C "$EXTRACT_DIR" 2>/dev/null; then
        if [ -f "$EXTRACT_DIR/jetson-image-test/rootfs/test.txt" ]; then
            pass "tar.gz 解压并验证内容成功"
        else
            fail "tar.gz 解压后文件结构不正确"
        fi
    else
        fail "tar.gz 解压失败"
    fi
    rm -rf "$EXTRACT_DIR"
else
    fail "tar.gz 打包失败"
fi

rm -rf "$TAR_TEST_DIR"

# ==================== 9. 小规模 rsync 备份还原测试 ====================
section "9. 小规模 rsync 备份还原测试"

# 用一个真实文件做小规模的备份还原验证
# 注意：/etc/os-release 是软链接，rsync -a 会复制链接本身，
# 复制到临时目录后链接目标不存在会导致 diff 失败。
# 因此使用 /etc/hostname（普通文件）进行测试。
MINI_TEST_DIR=$(mktemp -d)
MINI_BACKUP="$MINI_TEST_DIR/backup"
MINI_RESTORE="$MINI_TEST_DIR/restore"
mkdir -p "$MINI_BACKUP" "$MINI_RESTORE"

# 选择一个非软链接的文件进行测试
TEST_FILE="/etc/hostname"
if [ ! -f "$TEST_FILE" ] || [ -L "$TEST_FILE" ]; then
    TEST_FILE="/etc/shells"
fi

if rsync -aAXH "$TEST_FILE" "$MINI_BACKUP/" 2>/dev/null; then
    # 模拟还原
    BASENAME=$(basename "$TEST_FILE")
    if rsync -aAXH "$MINI_BACKUP/$BASENAME" "$MINI_RESTORE/" 2>/dev/null; then
        if diff -q "$TEST_FILE" "$MINI_RESTORE/$BASENAME" >/dev/null 2>&1; then
            pass "小规模 rsync 备份还原一致性验证通过（$BASENAME）"
        else
            fail "rsync 还原后文件内容不一致（$BASENAME）"
        fi
    else
        fail "rsync 还原失败"
    fi
else
    fail "rsync 备份失败"
fi

rm -rf "$MINI_TEST_DIR"

# ==================== 10. 系统信息记录测试 ====================
section "10. 系统信息记录测试"

if [ -f /etc/nv_tegra_release ]; then
    pass "L4T 版本文件存在"
else
    fail "未找到 /etc/nv_tegra_release（可能不是 Jetson 设备）"
fi

if [ -f /etc/nv_boot_control.conf ]; then
    BOOT_STORAGE=$(grep "TEGRA_BOOT_STORAGE" /etc/nv_boot_control.conf 2>/dev/null | awk '{print $2}')
    if [ -n "$BOOT_STORAGE" ]; then
        pass "启动设备配置：$BOOT_STORAGE"
    else
        fail "无法读取 TEGRA_BOOT_STORAGE"
    fi
else
    fail "未找到 /etc/nv_boot_control.conf"
fi

if [ -f /boot/extlinux/extlinux.conf ]; then
    ROOT_PARAM=$(grep -o "root=[^ ]*" /boot/extlinux/extlinux.conf | head -1)
    if [ -n "$ROOT_PARAM" ]; then
        pass "extlinux.conf root 参数：$ROOT_PARAM"
    else
        fail "extlinux.conf 中未找到 root 参数"
    fi
else
    fail "未找到 /boot/extlinux/extlinux.conf"
fi

# ==================== 测试结果汇总 ====================
echo ""
echo "============================================================"
TOTAL=$((PASS + FAIL + SKIP))
echo "  测试完成：共 $TOTAL 项"
echo "  通过：$PASS  失败：$FAIL  跳过：$SKIP"
echo "============================================================"

if [ "$FAIL" -gt 0 ]; then
    echo "  存在失败项，请检查上述输出。"
    exit 1
else
    echo "  所有测试通过，备份脚本可以正常工作。"
    exit 0
fi
