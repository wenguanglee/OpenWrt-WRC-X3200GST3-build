# OpenWrt-WRC-X3200GST3-build
OpenWrt build for ELECOM WRC-X3200GST3 with expand overlay 19 MiB → 109 MiB
正确的完整流程
当前官方 OpenWrt
原始分区：kernel 6 MiB，UBI 19 MiB
        │
        │ ① 刷入“原始分区＋KEXEC”的 sysupgrade.bin
        ▼
KEXEC 过渡系统
仍是原始分区，但具备内核 KEXEC 和用户态 kexec
        │
        │ ② 通过 kexec 启动“大分区 initramfs”
        │    实际加载其 Image、109 MiB DTB，以及所需 initrd
        ▼
大分区 RAM 临时系统
内核已按大分区设备树识别 UBI 109 MiB
        │
        │ ③ 确认运行环境、分区和镜像正确后
        │    执行 sysupgrade，写入“大分区 sysupgrade.bin”
        ▼
正式大分区系统
以后正常开机直接进入，不再需要经过 KEXEC 过渡系统

这里是两套构建、三份镜像：
一套原始布局的 KEXEC 构建，
以及一套包含 RAM 镜像和正式升级镜像的大分区构建。
三步分别用哪个文件？
各阶段	使用的镜像	操作目的
① 安装 KEXEC 过渡系统	原始分区构建中的 …squashfs-sysupgrade.bin	写入闪存，让当前系统具备 KEXEC
② 启动大分区临时系统	大分区构建中的 …initramfs-kernel.bin，提取所需组件后供 kexec 加载	切换到内存运行的新内核，让新分区定义生效
③ 安装正式大分区系统	大分区构建中的 …squashfs-sysupgrade.bin	写入匹配大分区布局的正式系统


**第一步与第三步的文件名可能完全相同，但内容、分区布局不同，必须按构建来源区分，不能只看文件名。**你提供的工作流正是通过读取镜像中的 DTB，而不是根据文件名，验证其是否为 109 MiB 布局。   貼り付けたテキスト（1）(1)
第二步还有一个关键点
不是直接执行 kexec …initramfs-kernel.bin 就行。

这款设备的内存固件是 FIT 容器；我们使用的 ARM64 kexec-tools 加载器没有直接列出 FIT 支持。因此，要先从大分区内存固件中提取内核、DTB，以及存在时的独立 initrd，并按实际镜像格式准备加载参数。尤其不能误用 KEXEC 过渡固件中的小分区 DTB。GitHub

加载完成和真正跳转成功也是两回事。只有成功进入新临时系统、重新连上 SSH，并检查分区正确之后，才进入第三步。
第三步才执行正式写入
在已经成功启动的大分区 RAM 系统中检查：
cat /proc/mtd
mount

本方案应看到：
mtd5: 00600000 00020000 "kernel"
mtd6: 06d00000 00020000 "ubi"

同时确认根文件系统确实来自 RAM，而不是闪存中的旧系统。`06d00000` 是本次大分区工作流规定的 UBI 长度；若仍是 01300000，不要继续。   貼り付けたテキスト（1）(1)

把大分区正式 sysupgrade 文件上传到这个临时系统的 /tmp/large-sysupgrade.bin，核对 SHA256，然后测试：
sha256sum /tmp/large-sysupgrade.bin

sysupgrade -T /tmp/large-sysupgrade.bin

备份已完成、运行环境和分区正确、校验一致、镜像检查通过后，才执行：
sysupgrade -n /tmp/large-sysupgrade.bin

-T 只检查、不刷写；`-n` 表示不保留旧配置。该机型的 NAND 升级流程会处理内核写入及 rootfs、`rootfs_data` 卷的重建，不用在前面额外手动擦除整个 NAND，也不要加 -F 强行绕过检查。GitHub

所以可以记成一句话：小分区 KEXEC 的 sysupgrade → 大分区 RAM 系统 → 大分区正式 sysupgrade；这条流程不使用 factory 固件。

迁移前要将配置、引导及校准分区、将被覆盖的 OEM 分区备份到电脑；不要把“从 RAM 启动”理解成整个过程绝不会改动闪存。这条路线仍未在你的设备上验证 kexec 跳转，编译成功不等于免拆机迁移已经验证成功，故障时也不能保证不需要串口恢复。
