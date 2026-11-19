# ELECOM WRC-X3200GST3 大分区刷机记录

适用环境：**ELECOM WRC-X3200GST3，已运行 OpenWrt 25.12.6，默认 19 MiB UBI 分区**。

本次通过 KEXEC 过渡固件，从 SSH 启动大分区内存系统，再安装正式固件，将 **UBI 从 19 MiB 扩为 109 MiB**。kernel 分区保持 6 MiB，不更换 U-Boot。本次操作已完成，但不保证所有设备均可无串口恢复。

> 操作前备份配置及全部现有 MTD 分区到电脑，并核对固件 SHA256。`sysupgrade -n` 不保留原配置，写入期间不能断电。109 MiB 是 UBI 总容量，不是 overlay 最终可用空间。

## 1. 需要的文件

将不同构建中的文件区分保存，下面使用短文件名方便操作。

| 文中使用的文件名 | 对应文件来源 | 作用 |
| --- | --- | --- |
| `bridge-sysupgrade.bin` | **原始分区 KEXEC 构建**的 `…squashfs-sysupgrade.bin` | 先刷入闪存，保持 19 MiB UBI，同时提供内核 KEXEC 支持和用户态 `kexec` 程序 |
| `initramfs.bin` | **109 MiB 大分区构建**的 `…initramfs-kernel.bin` | 临时运行在 RAM 中，内置大分区设备树；由脚本拆包后交给 kexec 启动 |
| `large-sysupgrade.bin` | **109 MiB 大分区构建**的 `…squashfs-sysupgrade.bin` | 最后在大分区 RAM 系统中刷入闪存，作为日常使用的正式系统 |
| `boot-large-no-wdt.sh` | 本目录附带的启动脚本 | 自动提取组件、解压内核、处理临时看门狗配置并执行 RAM 启动；不执行正式刷写 |

**两份 sysupgrade 的原文件名可能相同，必须按构建来源区分。重命名不会改变镜像内容。此流程不使用 `factory.bin`，也不能把 initramfs 当成 sysupgrade 刷入。**

流程：

```text
官方小分区 OpenWrt
  → 原分区 KEXEC 过渡固件
  → 大分区 RAM 系统
  → 大分区正式固件
```

## 2. 刷入 KEXEC 过渡固件

电脑用网线连接 LAN。以下假设路由器地址为 `192.168.1.1`，地址不同时请替换。

**电脑终端：**在文件所在目录上传。

```sh
scp -O bridge-sysupgrade.bin root@192.168.1.1:/tmp/bridge-sysupgrade.bin
```

**路由器 SSH：**核对 SHA256，然后检查并刷写。

```sh
sha256sum /tmp/bridge-sysupgrade.bin
sysupgrade -T /tmp/bridge-sysupgrade.bin && sysupgrade -n /tmp/bridge-sysupgrade.bin
```

重启后重新连接，确认 `kexec` 可以运行：

```sh
kexec --version
zcat /proc/config.gz | grep '^CONFIG_KEXEC=y$'
```

此时 UBI **仍是 19 MiB**，属于正常状态。不能仅安装一个 `kexec` 软件包来代替这个带内核支持的过渡固件。

## 3. 安装解包和解压工具

**在过渡系统的 SSH 中执行，路由器需能访问软件源：**

```sh
apk update && apk add dumpimage fdt-utils xz
```

| 工具 | 用途 |
| --- | --- |
| `dumpimage` | 从 FIT 镜像中提取 kernel、initrd、DTB |
| `fdt-utils` | 提供 `fdtget`、`fdtdump`、`fdtput`，读取和修改临时 DTB |
| `xz` | 解压 LZMA 内核，得到 ARM64 `Image` |
| `kexec` | 加载并切换内核，已集成在过渡固件中 |

脚本使用系统自带的 **`sh`** 执行，**不用额外安装 Bash 或 Python**。

## 4. 启动大分区 RAM 系统

**电脑终端：**上传大分区 RAM 镜像和脚本。不要提前把正式镜像只放在路由器 `/tmp`，切换内核后旧 `/tmp` 的文件不会保留。

```sh
scp -O initramfs.bin boot-large-no-wdt.sh root@192.168.1.1:/tmp/
```

RAM 启动阶段可将电脑有线网卡设为 **`192.168.1.2/24`**，继续连接 LAN，避免依赖 DHCP 获取地址。

**路由器 SSH：**

```sh
sh /tmp/boot-initramfs.sh
```

脚本自动完成：

```text
FIT 拆包 → 提取内核、initrd、DTB → 解压内核
  → 在临时 DTB 副本中禁用 watchdog
  → kexec 加载 → 同步文件系统、关闭当前 watchdog → 切换内核
```

**本次最初的 RAM 启动曾自动复位；使用临时禁用目标 watchdog 的脚本后，成功进入大分区系统。**这不表示已确定所有复位的根因，也不需要把看门狗禁用设置写进正式固件。脚本只修改 `/tmp` 中的 DTB 副本，不修改原始 FIT。

SSH 断开后重新连接：

```sh
ssh root@192.168.1.1
```

在路由器上确认：

```sh
cat /proc/mtd
ubus call system board | grep rootfs_type
```

应同时出现：

```text
mtd6: 06d00000 00020000 "ubi"
"rootfs_type": "initramfs"
```

**只有大分区 RAM 系统能稳定运行时才继续。若仍是 `01300000`、`squashfs`，或反复断线复位，不要刷写。**

## 5. 刷入正式大分区固件

**电脑终端：**重新上传正式大分区镜像。

```sh
scp -O large-sysupgrade.bin root@192.168.1.1:/tmp/large-sysupgrade.bin
```

**路由器 SSH：**核对 SHA256 与电脑下载包中的对应值一致。

```sh
sha256sum /tmp/large-sysupgrade.bin
```

确认当前仍是上一步的“大分区＋initramfs”，再执行：

```sh
sysupgrade -T /tmp/large-sysupgrade.bin && sysupgrade -n /tmp/large-sysupgrade.bin
```

开始刷写后不要断电。此流程不需要另外执行 `mtd erase` 或 `ubiformat`，不使用 `-F` 强刷。

## 6. 完成后确认

重启并重新连接，执行：

```sh
cat /proc/mtd
ubus call system board | grep rootfs_type
df -h /overlay
```

正式系统应保持 **`06d00000 "ubi"`**，根文件系统变为 **`squashfs`**，`/overlay` 正常挂载。实际可用空间以 `df` 输出为准。

**后续升级继续使用相同 109 MiB 分区布局的固件，不直接刷回官方小分区固件或 KEXEC 原分区过渡固件。**

---
已经测试成功。
wrc-x3200gst3-openwrt-KERNEL-KEXEC 包含 原厂分区 过度image  initramfs.bin 和 sysupgrade.bin
OpenWrt-WRC-X3200GST3-build 包含 109M 大分区 initramfs.bin 和 sysupgrade.bin
刷机步骤 
1 刷入主线openwrt factory 固件
2 在openwrt 里面 sysupgrade 升级 带kexec 程序的wrc-x3200gst3-openwrt-KERNEL-KEXEC sysupgrade.bin
3 在新的kexec openwrt 里面 使用上面描述细节 启动 大分区  initramfs.bin
4 在大分区 ramfs里面 openwrt 页面 刷写 大分区 sysupgrade.bin
