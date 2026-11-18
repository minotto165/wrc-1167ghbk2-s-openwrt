#!/bin/bash
# ============================================================
# コンテナ内で「本物の ash + 本物の uci」で setup.sh を走らせる
#   ash : rootfs の /bin/sh (busybox ash 1.37, mipsel, musl) を qemu-mipsel-static で実行
#   uci : rootfs の /sbin/uci (mipsel ELF) を呼ぶラッパーを PATH (/w/bin) に置く
#   /etc/config : コンテナの /etc/config を rootfs の etc/config に symlink
#                 （qemu-user はゲストの絶対パスを書き換えないのでホスト側で合わせる）
#
# 注意:
#   * ゲストの PATH にホストのバイナリ(/usr/bin 等)を入れると、ゲストが x86 ELF を
#     exec しようとして qemu が Segfault する。ゲスト PATH は rootfs 内だけにする。
#   * ラッパー(/w/bin/uci)はホストの /bin/sh が実行するので、qemu は絶対パスで呼ぶ。
#
# 使い方: bash /e/in-container-run.sh <label> [ubus-stub]
# ============================================================
set -u
LABEL=${1:-run1}
UBUS_STUB=${2:-no}
W=/w
ROOTFS=$W/rootfs
CONFDIR=$ROOTFS/etc/config
mkdir -p "$W/bin" "$W/logs"
LOG=$W/logs/$LABEL.log
exec > >(tee "$LOG") 2>&1

echo "### label=$LABEL ubus_stub=$UBUS_STUB date=$(date -Is)"

chmod +x "$ROOTFS/sbin/uci" "$ROOTFS/bin/sh" "$ROOTFS/bin/busybox" 2>/dev/null

# qemu-user は「ゲストが exec する別の mipsel バイナリ」を扱えない（ENOEXEC/segv）。
# そこで PATH 上のコマンドは全部「ホスト sh のラッパー → qemu-mipsel」にする。
mk_wrap() {  # $1 = コマンド名 (rootfs/bin か rootfs/sbin のどちらか)
	name=$1
	for d in "$ROOTFS/bin" "$ROOTFS/sbin" "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin"; do
		if [ -e "$d/$name" ]; then
			cat > "$W/bin/$name" <<EOS
#!/bin/sh
exec /usr/bin/qemu-mipsel-static -L $ROOTFS $d/$name "\$@"
EOS
			chmod +x "$W/bin/$name"
			return 0
		fi
	done
}
for a in grep sed head tail tr cut sort uniq cat printf sleep awk mkdir cp mv rm ln \
	 date uname wc expr basename dirname id yes seq sha256sum md5sum find xargs \
	 logread ubus uci wifi; do
	mk_wrap "$a"
done
# 実機と同じ /sbin/uci を指していることを確認（ラッパー経由）
cat "$W/bin/uci"

if [ "$UBUS_STUB" = "ubus-stub" ]; then
	cat > "$W/bin/ubus" <<'EOS'
#!/bin/sh
# 実機なら procd/ubus が返す応答の代役（qemu 上では netifd が動かないため）
case "$*" in
  "call network.interface.wwan status")
	echo '{"up": true, "interface": "wwan", "ipv4-address": [{"address":"10.8.0.42","mask":24}]}'
	;;
  *) exit 1 ;;
esac
EOS
	chmod +x "$W/bin/ubus"
else
	rm -f "$W/bin/ubus"
fi

cat > "$W/bin/fw-stub" <<'EOS'
#!/bin/sh
echo "[fw-stub] called: $*" >> /w/logs/fw-stub.calls
exit 0
EOS
chmod +x "$W/bin/fw-stub"
rm -f /etc/config
ln -sfn "$CONFDIR" /etc/config

for f in network wireless firewall; do
	[ -f "$W/pristine/$f" ] || cp "$CONFDIR/$f" "$W/pristine/$f"
	cp "$W/pristine/$f" "$CONFDIR/$f"
done

export QEMU_LD_PREFIX=$ROOTFS
GPATH="$W/bin"     # ゲスト側の PATH（全部ラッパー経由）

show() { /usr/bin/qemu-mipsel-static -L "$ROOTFS" "$ROOTFS/sbin/uci" show "$1"; }
gsh()  { /usr/bin/qemu-mipsel-static -L "$ROOTFS" "$ROOTFS/bin/sh" -c "$1"; }

echo "--- 何を実行しているか ---"
echo "shell: $ROOTFS/bin/sh (busybox ash, mipsel musl) / uci: $ROOTFS/sbin/uci"
gsh 'echo "  ash version: busybox sh on $(uname -m), pid=$$"'

show wireless > "$W/logs/$LABEL-wireless-before.txt" 2>&1
show network  > "$W/logs/$LABEL-network-before.txt" 2>&1
show firewall > "$W/logs/$LABEL-firewall-before.txt" 2>&1

echo "--- setup.sh 実行 ---"
start=$(date +%s)
env -i PATH="$GPATH" QEMU_LD_PREFIX="$ROOTFS" \
	UCI=uci WIFI=wifi FW_INIT="$W/bin/fw-stub" UBUS="$W/bin/ubus" \
	LOGREAD=logread SLEEP=sleep \
	WAIT_WIFI="${WAIT_WIFI:-2}" WAIT_WAN="${WAIT_WAN:-2}" \
	SCHOOL_SSID="TEST-CAMPUS-WPA2" EAP_IDENTITY="s2345678@example.ac.jp" \
	EAP_PASSWORD="p@ssw0rd-dummy" EAP_TYPE=peap EAP_AUTH=MSCHAPV2 \
	CA_USESYSTEM=1 PMF=0 STA_BAND=5g AP_BAND=2g \
	AP_SSID="MyRouter-emul" AP_KEY="openwrt1234" AP_CHANNEL=6 \
	/usr/bin/qemu-mipsel-static -L "$ROOTFS" "$ROOTFS/bin/sh" "$W/setup.sh"
rc=$?
end=$(date +%s)
echo "### setup.sh exit=$rc  elapsed=$((end-start))s"

show wireless > "$W/logs/$LABEL-wireless-after.txt" 2>&1
show network  > "$W/logs/$LABEL-network-after.txt" 2>&1
show firewall > "$W/logs/$LABEL-firewall-after.txt" 2>&1
mkdir -p "$W/logs/$LABEL-config"; cp "$CONFDIR"/* "$W/logs/$LABEL-config/" 2>/dev/null

echo "--- wireless: 生成された sta_wan ---"
grep -A14 -- sta_wan "$W/logs/$LABEL-wireless-after.txt" | head -20
echo "--- firewall: wan ゾーンの network リスト ---"
grep -B2 -A8 -- "-name='wan'" "$W/logs/$LABEL-firewall-after.txt" | head -20 || true
grep 'network' "$W/logs/$LABEL-firewall-after.txt" | head -6
echo "### done rc=$rc"
exit $rc
