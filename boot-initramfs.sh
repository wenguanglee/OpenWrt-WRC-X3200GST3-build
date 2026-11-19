#!/bin/sh
# WRC-X3200GST3: RAM-only diagnostic retry. Target watchdog disabled.
# This is NOT a proven boot fix. A hang may require manual power cycling.
# No sysupgrade, erase, bootloader or flash-write operation is performed.
set -eu
trap '' HUP

FIT=/tmp/initramfs.bin
OUT=/tmp/kexec-large
RO=0
WD=0
EXEC_TRIED=0

fail() { echo "停止：$*" >&2; exit 1; }
cleanup() {
    RC=$?
    trap - 0
    if [ "$RO" = 1 ]; then
        mount -o remount,rw /overlay || true
    fi
    if [ "$WD" = 1 ]; then
        ubus call system watchdog '{"magicclose":false,"stop":false}' || true
    fi
    if [ "$EXEC_TRIED" = 1 ]; then
        /etc/init.d/network restart || true
    fi
    if [ "$RC" -ne 0 ]; then
        echo "未完成 RAM 启动；本脚本没有执行正式固件刷写。" >&2
    fi
    exit "$RC"
}
trap cleanup 0

for C in dumpimage fdtget fdtput fdtdump xz kexec ubus; do
    command -v "$C" >/dev/null 2>&1 || fail "缺少工具 $C"
done
[ -s "$FIT" ] || fail "请重新上传大分区 RAM 镜像到 $FIT"
[ "$(cat /proc/sys/kernel/kexec_load_disabled)" = 0 ] || fail "内核禁止 KEXEC"
mkdir -p "$OUT"

echo "[1/5] 从 FIT 默认配置中提取三个组件"
CONF="$(fdtget -t s "$FIT" /configurations default)"
KERNEL="$(fdtget -t s "$FIT" "/configurations/$CONF" kernel)"
INITRD="$(fdtget -t s "$FIT" "/configurations/$CONF" ramdisk)"
FDT="$(fdtget -t s "$FIT" "/configurations/$CONF" fdt)"
[ "$(fdtget -t s "$FIT" "/images/$KERNEL" type)" = kernel ] || fail "内核组件类型错误"
[ "$(fdtget -t s "$FIT" "/images/$INITRD" type)" = ramdisk ] || fail "缺少独立 initrd"
[ "$(fdtget -t s "$FIT" "/images/$FDT" type)" = flat_dt ] || fail "DTB 类型错误"
[ "$(fdtget -t s -d none "$FIT" "/images/$FDT" compression)" = none ] || fail "DTB 被压缩"
fdtget -l "$FIT" /images > "$OUT/nodes.txt"

extract_node() {
    NODE="$1"
    DEST="$2"
    INDEX="$(awk -v node="$NODE" '
        $0 == node { print NR-1; found++ }
        END { if (found != 1) exit 1 }
    ' "$OUT/nodes.txt")"
    dumpimage -T flat_dt -p "$INDEX" -o "$DEST" "$FIT"
    [ -s "$DEST" ] || fail "组件提取为空：$NODE"
}
extract_node "$KERNEL" "$OUT/kernel.payload"
extract_node "$INITRD" "$OUT/initrd"
extract_node "$FDT" "$OUT/large.dtb"

echo "[2/5] 解压内核；initrd 保持提取后的原样"
COMP="$(fdtget -t s -d none "$FIT" "/images/$KERNEL" compression)"
case "$COMP" in
    lzma) xz --format=lzma -dc "$OUT/kernel.payload" > "$OUT/Image" ;;
    gzip) gzip -dc "$OUT/kernel.payload" > "$OUT/Image" ;;
    none) cp "$OUT/kernel.payload" "$OUT/Image" ;;
    *) fail "未处理的内核压缩格式：$COMP" ;;
esac
MAGIC="$(dd if="$OUT/Image" bs=1 skip=56 count=4 2>/dev/null | hexdump -v -e '1/1 "%02x"')"
[ "$MAGIC" = 41524d64 ] || fail "解压结果不是 ARM64 Image"
[ "$(fdtget -t s "$OUT/large.dtb" / model)" = 'ELECOM WRC-X3200GST3' ] || fail "DTB 机型不符"
fdtdump "$OUT/large.dtb" > "$OUT/large.dts" 2>/dev/null
#sed -n '/partition@8c0000[[:space:]]*{/,/};/p' "$OUT/large.dts" |
#    grep -Eq 'reg = <0x0*8c0000 0x0*6d00000>;' || fail "DTB 不是 109 MiB UBI"

# Change ONE target-kernel variable: hide the hardware watchdog from the
# next Linux instance. The original extracted DTB and FIT remain unchanged.
# The source-kernel watchdog is still closed later, as in the previous script.
WDT_NODE=/watchdog@10212000
TARGET_DTB="$OUT/large-no-wdt.dtb"
fdtget -t s "$OUT/large.dtb" "$WDT_NODE" compatible |
    grep -q 'mediatek,mt7622-wdt' || fail "目标看门狗节点不符合本机型"
cp "$OUT/large.dtb" "$TARGET_DTB"
fdtput -t s "$TARGET_DTB" "$WDT_NODE" status disabled
[ "$(fdtget -t s "$TARGET_DTB" "$WDT_NODE" status)" = disabled ] ||
    fail "未能禁用诊断 DTB 中的看门狗"
echo "诊断试验：仅下一 RAM 系统的 watchdog 节点被禁用。"
echo "这不是已验证的修复；若挂起，可能需要手动断电重启。"

echo "[3/5] 重新加载 Image、initrd、大分区 DTB"
if [ "$(cat /sys/kernel/kexec_loaded)" = 1 ]; then
    kexec -c -u
fi
CMDLINE='earlycon=uart8250,mmio32,0x11002000 console=ttyS0,115200n8 swiotlb=512'
if kexec -d -c -l "$OUT/Image" \
    --type=Image \
    --dtb="$TARGET_DTB" \
    --initrd="$OUT/initrd" \
    --append="$CMDLINE" > "$OUT/load.log" 2>&1; then
    tail -n 25 "$OUT/load.log"
else
    cat "$OUT/load.log"
    fail "kexec 加载失败"
fi
[ "$(cat /sys/kernel/kexec_loaded)" = 1 ] || fail "下一内核未成功加载"

echo "[4/5] 同步文件系统并关闭看门狗"
sync
mount -o remount,ro /overlay
RO=1
WD=1
ubus call system watchdog '{"magicclose":true,"stop":true}'
if [ -r /sys/class/watchdog/watchdog0/state ]; then
    [ "$(cat /sys/class/watchdog/watchdog0/state)" = inactive ] || fail "看门狗仍处于活动状态"
fi

echo "[5/5] 现在执行 RAM 启动，SSH 将断开"
echo "重新连接后：cat /proc/mtd ; ubus call system board"
sync
EXEC_TRIED=1
kexec -c -e > "$OUT/exec.log" 2>&1 || {
    cat "$OUT/exec.log"
    fail "kexec 执行失败并返回"
}
fail "kexec 意外返回，未成功切换内核"
