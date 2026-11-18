#!/bin/bash
# コンテナ内で mipsel(32bit LE) の binfmt を登録する（--privileged 必須）
#   * register へは「\x7f のようなエスケープ文字列」をそのまま書く（生バイトだと EINVAL）
#   * register は 1 行 256 バイト未満しか受け付けない
#   * flags に P (preserve-argv0) はこの VM のカーネルでは EINVAL になった
#   * ワイルドカード（mask を全部 0xff にする等）は絶対に登録しない。
#     共有 VM の binfmt テーブルを壊し、containerd まで動かなくなる。
set -u
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
REG=/proc/sys/fs/binfmt_misc/register
[ -e "$REG" ] || { echo "FAIL: $REG が無い（--privileged で起動しているか）"; exit 1; }
if [ -e /proc/sys/fs/binfmt_misc/mipsel ]; then
	echo "already registered"
	exit 0
fi

# ELF32 LE / e_machine=MIPS(8) までを判定（20B）
magic='\x7f\x45\x4c\x46\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x08\x00'
mask='\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff'

interp=/qemu-mipsel-static     # rootfs 内に置いた static qemu（chroot 内から解決させる）

for fl in "" "C" "CF"; do
	printf '%s' ":mipsel:M::${magic}::${mask}::${interp}:${fl}" > "$REG" 2>/dev/null && {
		echo "registered flags=[${fl}]"; sed -n '1,4p' /proc/sys/fs/binfmt_misc/mipsel; exit 0; }
done
echo "FAIL: どのフラグでも登録できなかった"
exit 1
