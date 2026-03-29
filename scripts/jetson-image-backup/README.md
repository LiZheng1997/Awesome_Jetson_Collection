# Jetson Orin NVMe 系统镜像备份与部署方案

适用于小型科研团队的 Jetson 系统镜像管理方案，支持快速备份、全量恢复和增量更新。

## 适用平台

- Jetson AGX Orin / Orin NX / Orin Nano
- JetPack 6.x (L4T 36.x)
- NVMe SSD 作为系统盘启动

## 架构说明

Jetson Orin 的启动链分为两个独立部分：

```
QSPI-NOR Flash（模块上）          NVMe SSD
┌──────────────────────┐    ┌────────────────────────────┐
│ MB1 → MB2 → UEFI    │───>│ p1  APP (rootfs)           │
│ BCT、安全启动密钥     │    │ p2  A_kernel               │
│ 固件分区              │    │ p3  A_kernel-dtb           │
│                      │    │ p5  B_kernel               │
│ 刷写方式：            │    │ p6  B_kernel-dtb           │
│ SDK Manager / flash.sh│    │ p10 ESP                    │
└──────────────────────┘    │ p8  recovery               │
                            │ ... 共 15 个分区             │
                            │                            │
                            │ 备份方式：本方案的脚本        │
                            └────────────────────────────┘
```

**本方案只负责 NVMe SSD 的备份与恢复。** QSPI 引导分区需要通过 NVIDIA SDK Manager 或 `flash.sh` 单独刷写。

## 工作流程

### 场景 1：创建黄金镜像 + 全量部署新设备

```
┌─────────────┐    backup.sh     ┌─────────────┐    restore.sh    ┌─────────────┐
│  黄金镜像机   │ ──────────────> │  .tar.gz     │ ──────────────> │  新 Jetson    │
│  (配置完毕)   │                 │  压缩包       │                 │  (同型号)     │
└─────────────┘                  └─────────────┘                  └─────────────┘
```

1. 在一台 Jetson 上配置好所有环境（称为"黄金镜像机"）
2. 运行 `backup.sh` 创建压缩镜像包
3. 新设备先用 SDK Manager 刷 QSPI
4. 从 USB/eMMC 临时系统启动，运行 `restore.sh` 恢复 NVMe

### 场景 2：迭代更新已部署设备

```
┌─────────────┐  deploy-update.sh  ┌─────────────┐
│  黄金镜像机   │ ───── rsync ────> │  已部署设备    │
│  (已更新)     │    (仅传输差异)    │  192.168.x.x │
└─────────────┘                    └─────────────┘
```

1. 在黄金镜像机上更新软件/配置
2. 运行 `deploy-update.sh` 将变化增量同步到目标设备
3. 目标设备重启生效

## 脚本说明

| 脚本 | 功能 | 运行位置 | 需要 sudo |
|------|------|----------|-----------|
| `backup.sh` | 全量备份 NVMe 为 .tar.gz | 黄金镜像机上 | 是 |
| `restore.sh` | 恢复 .tar.gz 到新 NVMe | 目标设备上（从临时系统启动） | 是 |
| `deploy-update.sh` | rsync 增量同步到远程设备 | 黄金镜像机上 | 是 |

## 使用方法

### 备份

```bash
# 备份到外接 USB 硬盘
sudo ./backup.sh /media/lz/usb-drive/backups

# 备份到默认目录 /tmp/jetson-backup
sudo ./backup.sh
```

备份内容：
- GPT 分区表
- rootfs 全部文件（rsync，排除虚拟文件系统和缓存）
- 非 rootfs 分区的 dd 镜像（kernel、DTB、ESP、recovery 等）
- 系统信息记录（L4T 版本、已安装包列表等）

### 恢复到新设备

**第 1 步**：在 x86 主机上刷写 QSPI（仅引导分区，不刷 NVMe）

```bash
# 在 x86 主机的 Linux_for_Tegra 目录下
# 目标 Jetson 需进入 Force Recovery 模式（按住 REC 键，按一下 RESET）
sudo ./flash.sh -c bootloader/generic/cfg/flash_t234_qspi.xml \
    --no-systemimg jetson-agx-orin-devkit mmcblk0p1
```

**第 2 步**：从 USB/eMMC 临时系统启动目标 Jetson，恢复 NVMe

```bash
sudo ./restore.sh /media/lz/usb/jetson-image-20260329-120000.tar.gz
```

### 增量更新

```bash
# 前提：已配置 SSH 密钥免密登录
ssh-copy-id lz@192.168.8.10

# 从黄金镜像机推送更新到目标设备
sudo ./deploy-update.sh 192.168.8.10 lz
```

增量更新会自动排除设备特定文件（hostname、machine-id、SSH 密钥、网络配置），不会破坏目标设备的个性化配置。

## 建议的团队实践

1. **版本管理**：备份文件名包含时间戳，建议额外维护一个 changelog 记录每个版本的变化
2. **备份前精简**：运行 `sudo apt clean` 和清理不需要的文件，减小镜像体积
3. **存储**：将 .tar.gz 镜像存放在 NAS 或团队共享硬盘上，方便团队成员取用
4. **SSH 密钥**：团队所有 Jetson 设备配置统一的 SSH 授权密钥，便于增量部署
5. **QSPI 版本**：所有设备使用相同版本的 JetPack 刷写 QSPI，确保引导兼容性
