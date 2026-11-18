#!/bin/sh
# ============================================================
# WRC-1167GHBK2-S / OpenWrt 25.12.x
#   学校Wi-Fi (WPA2-Enterprise) に STA として接続し、
#   自前SSIDで再放出する (WWAN -> LAN の NAT)
#
#   ルーター上で:  sh setup.sh
#   何度実行しても同じ結果になる（冪等）ように作ってある。
# ============================================================
set -u

# ---- 注入口（通常は触らない。テスト時に差し替える） --------
UCI="${UCI:-uci}"
WIFI="${WIFI:-wifi}"
FW_INIT="${FW_INIT:-/etc/init.d/firewall}"
IFUP="${IFUP:-ifup}"
UBUS="${UBUS:-ubus}"
LOGREAD="${LOGREAD:-logread}"
SLEEP="${SLEEP:-sleep}"
WAIT_WIFI="${WAIT_WIFI:-30}"   # 無線設定が生成されるまで待つ秒数
WAIT_WAN="${WAIT_WAN:-60}"     # wwan が up になるまで待つ秒数

# ---- ここを書き換える --------------------------------------
SCHOOL_SSID="${SCHOOL_SSID:-CHANGE-ME-CAMPUS-SSID}"
EAP_IDENTITY="${EAP_IDENTITY:-CHANGE-ME@example.ac.jp}"
EAP_PASSWORD="${EAP_PASSWORD:-CHANGE-ME}"
EAP_TYPE="${EAP_TYPE:-peap}"        # peap / ttls / tls
EAP_AUTH="${EAP_AUTH-MSCHAPV2}"    # PEAP・TTLS-> MSCHAPV2 or PAP / TLS-> 空（空にするには EAP_AUTH= を明示）
EAP_ANON="${EAP_ANON:-}"            # 匿名ID。不要なら空のまま
CA_USESYSTEM="${CA_USESYSTEM:-1}"   # 1=システムCAで検証 / 0=検証しない
CA_CERT="${CA_CERT:-}"              # 学内私設CAのPEMパス（指定時はこちらを優先）
PMF="${PMF:-1}"                     # 802.11w: 0=無効 1=任意(optional) 2=必須(required)
STA_BAND="${STA_BAND:-5g}"          # 学校へ出る側のバンド
AP_BAND="${AP_BAND:-2g}"            # 自分へ出す側のバンド
AP_SSID="${AP_SSID:-MyRouter}"
AP_KEY="${AP_KEY:-openwrt1234}"
AP_CHANNEL="${AP_CHANNEL:-}"        # 空なら 2g=6 / 5g=auto を自動選択
# ------------------------------------------------------------

log()  { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARN: %s\n' "$*" >&2; }
die()  { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

u() { "$UCI" -q "$@"; }

# band='2g' 等から wifi-device のセクション名を引く
band_radio() {
	u show wireless 2>/dev/null \
		| sed -n "s/^wireless\.\([^.]*\)\.band='$1'\$/\1/p" \
		| head -n1
}

# wifi-iface のセクション名一覧
iface_list() {
	u show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'
}

# 指定デバイス上で mode=ap の wifi-iface を引く
ap_iface_on() {
	for s in $(iface_list); do
		if [ "$(u get wireless.$s.device 2>/dev/null)" = "$1" ] \
		   && [ "$(u get wireless.$s.mode 2>/dev/null)" = "ap" ]; then
			echo "$s"
			return 0
		fi
	done
	return 0
}

# --- 0) 前提チェック -----------------------------------------
command -v "$UCI" >/dev/null 2>&1 || die "uci が見つかりません（OpenWrt 上で実行してください）"
command -v "$WIFI" >/dev/null 2>&1 || warn "wifi コマンドが見つかりません"

# WPA2-Enterprise には EAP 対応の wpad（full 系）が必須
WPAD=""
if command -v apk >/dev/null 2>&1; then
	WPAD=$(apk info 2>/dev/null | sed -n 's/^\(wpad[^ ]*\).*/\1/p' | head -n1)
elif command -v opkg >/dev/null 2>&1; then
	WPAD=$(opkg list-installed 2>/dev/null | sed -n 's/^\(wpad[^ ]*\) .*/\1/p' | head -n1)
fi
case "$WPAD" in
	wpad-basic*|wpad-mini*|wpad)
		die "EAP 非対応の $WPAD が入っています。wpad-mbedtls / wpad-openssl / wpad-wolfssl が必要です" ;;
	'')	warn "wpad パッケージが確認できませんでした（EAP が使えない可能性）" ;;
	*)	log "wpad=$WPAD" ;;
esac

if [ "$CA_USESYSTEM" = "1" ] && [ -z "$CA_CERT" ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
	warn "/etc/ssl/certs/ca-certificates.crt がありません（ca-bundle 未導入）。証明書は検証されません"
fi

if [ ! -f /etc/config/wireless ]; then
	log "/etc/config/wireless が無いので生成します"
	$WIFI config >/dev/null 2>&1
fi

# --- 1) 無線設定の生成待ち -----------------------------------
i=0
while [ "$i" -lt "$WAIT_WIFI" ]; do
	if u show wireless 2>/dev/null | grep -q '\.band='; then
		break
	fi
	$SLEEP 1
	i=$((i + 1))
done
if ! u show wireless 2>/dev/null | grep -q '\.band='; then
	$WIFI config >/dev/null 2>&1
	$SLEEP 2
fi
u show wireless 2>/dev/null | grep -q '\.band=' || die "無線設定が生成されませんでした（'wifi config' を手で実行してください）"

# --- 2) ラジオの特定 -----------------------------------------
DEV_STA=$(band_radio "$STA_BAND")
[ -n "$DEV_STA" ] || die "band=$STA_BAND の無線デバイスが見つかりません（'uci show wireless' を確認）"
DEV_AP=$(band_radio "$AP_BAND")
[ -n "$DEV_AP" ] || die "band=$AP_BAND の無線デバイスが見つかりません（'uci show wireless' を確認）"

if [ "$DEV_STA" = "$DEV_AP" ]; then
	warn "STA と AP が同じラジオ ($DEV_STA) です。不安定になる場合があります"
fi
log "STA側=$DEV_STA ($STA_BAND) / AP側=$DEV_AP ($AP_BAND)"

# --- 3) 国コードと有効化 -------------------------------------
for d in $(u show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'); do
	u set wireless.$d.country='JP'
	u set wireless.$d.disabled='0'
done

# AP 側のチャネル（バンドと矛盾しない値だけ書く）
if [ -z "$AP_CHANNEL" ]; then
	case "$AP_BAND" in
		2g) AP_CHANNEL='6' ;;
		*)  AP_CHANNEL='auto' ;;
	esac
fi
case "$AP_BAND:$AP_CHANNEL" in
	5g:[1-9]|5g:1[0-4]|6g:[1-9]|6g:1[0-4])
		warn "$AP_BAND ラジオに 2.4GHz 用チャネル($AP_CHANNEL)は使えません。auto にします"
		AP_CHANNEL='auto' ;;
esac
u set wireless.$DEV_AP.channel="$AP_CHANNEL"

# --- 4) WWAN インターフェース --------------------------------
if ! u get network.wwan >/dev/null 2>&1; then
	u set network.wwan=interface
fi
u set network.wwan.proto='dhcp'
u set network.wwan.disabled='0'

# --- 5) 既存の STA iface を掃除（同じラジオに2本生えるのを防ぐ）
for s in $(iface_list); do
	[ "$s" = "sta_wan" ] && continue
	[ "$(u get wireless.$s.device 2>/dev/null)" = "$DEV_STA" ] || continue
	[ "$(u get wireless.$s.mode 2>/dev/null)" = "sta" ] || continue
	u delete wireless.$s
	log "既存の STA iface ($s) を削除しました"
done

# --- 6) STA 側 (削除して作り直す = 冪等) ---------------------
u delete wireless.sta_wan
u set wireless.sta_wan=wifi-iface
u set wireless.sta_wan.device="$DEV_STA"
u set wireless.sta_wan.mode='sta'
u set wireless.sta_wan.network='wwan'
u set wireless.sta_wan.ssid="$SCHOOL_SSID"
u set wireless.sta_wan.encryption='wpa2'
u set wireless.sta_wan.eap_type="$EAP_TYPE"
u set wireless.sta_wan.identity="$EAP_IDENTITY"
u set wireless.sta_wan.password="$EAP_PASSWORD"
u set wireless.sta_wan.ieee80211w="$PMF"
if [ -n "$EAP_AUTH" ]; then u set wireless.sta_wan.auth="$EAP_AUTH"; fi
if [ -n "$EAP_ANON" ]; then u set wireless.sta_wan.anonymous_identity="$EAP_ANON"; fi
# 証明書: 私設CAが指定されていればそちらを優先（ca_cert_usesystem と併用不可）
if [ -n "$CA_CERT" ]; then
	u set wireless.sta_wan.ca_cert_usesystem='0'
	u set wireless.sta_wan.ca_cert="$CA_CERT"
	log "クライアント証明書CA: $CA_CERT"
else
	u set wireless.sta_wan.ca_cert_usesystem="$CA_USESYSTEM"
fi

# --- 7) AP 側 ------------------------------------------------
AP_IF=$(ap_iface_on "$DEV_AP")
if [ -z "$AP_IF" ]; then
	AP_IF='ap_lan'
	u set wireless.$AP_IF=wifi-iface
	u set wireless.$AP_IF.device="$DEV_AP"
	u set wireless.$AP_IF.mode='ap'
	u set wireless.$AP_IF.network='lan'
fi
u set wireless.$AP_IF.disabled='0'
u set wireless.$AP_IF.ssid="$AP_SSID"
u set wireless.$AP_IF.encryption='psk2'
u set wireless.$AP_IF.key="$AP_KEY"
log "AP側 iface=$AP_IF (ssid=$AP_SSID)"

# --- 8) STA ラジオ上の AP を止める ---------------------------
for s in $(iface_list); do
	[ "$s" = "sta_wan" ] && continue
	[ "$s" = "$AP_IF" ] && continue
	[ "$(u get wireless.$s.device 2>/dev/null)" = "$DEV_STA" ] || continue
	[ "$(u get wireless.$s.mode 2>/dev/null)" = "ap" ] || continue
	u set wireless.$s.disabled='1'
	log "STA ラジオの AP ($s) を無効化しました"
done

# --- 9) ファイアウォール (wwan を wan ゾーンへ) ---------------
zone_list() {
	u show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=zone$/\1/p'
}

find_wan_zone() {
	# 1) name='wan'
	local z
	z=$(u show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -n1)
	[ -n "$z" ] && { echo "$z"; return 0; }
	# 2) network に wan を含むゾーン
	for x in $(zone_list); do
		if u get firewall.$x.network 2>/dev/null | tr ' ' '\n' | grep -qx 'wan'; then
			echo "$x"
			return 0
		fi
	done
	# 3) 最後のゾーン（fw4 の既定 wan は末尾）。lan/lan6 は絶対に選ばない
	z=""
	for x in $(zone_list); do
		n=$(u get firewall.$x.name 2>/dev/null)
		case "$n" in lan|lan6) continue ;; esac
		z="$x"
	done
	[ -n "$z" ] && warn "wan ゾーンを名前で特定できず、末尾の非lanゾーン($z)を使います"
	echo "$z"
}

WAN_ZONE=$(find_wan_zone)
[ -n "$WAN_ZONE" ] || die "wan ゾーンが見つかりません（/etc/config/firewall を確認）"
u set firewall.$WAN_ZONE.masq='1'
if ! u get firewall.$WAN_ZONE.network 2>/dev/null | tr ' ' '\n' | grep -qx 'wwan'; then
	u add_list firewall.$WAN_ZONE.network='wwan'
	if ! u get firewall.$WAN_ZONE.network 2>/dev/null | tr ' ' '\n' | grep -qx 'wwan'; then
		die "wan ゾーン($WAN_ZONE)に wwan を追加できませんでした"
	fi
fi
log "wan ゾーン=$WAN_ZONE に wwan を追加"

# --- 10) 反映 ------------------------------------------------
u commit network
u commit wireless
u commit firewall

$WIFI reload >/dev/null 2>&1
if command -v "$IFUP" >/dev/null 2>&1; then
	$IFUP wwan >/dev/null 2>&1 || true
else
	warn "$IFUP が見つかりません。wwan は自動で上がらない可能性があります（手動: ifup wwan）"
fi
if [ -x "$FW_INIT" ]; then
	if ! "$FW_INIT" restart >/dev/null 2>&1; then
		warn "firewall の再起動に失敗しました"
	fi
fi

# --- 11) wwan の up 待ち -------------------------------------
i=0
up=0
while [ "$i" -lt "$WAIT_WAN" ]; do
	if $UBUS call network.interface.wwan status 2>/dev/null | grep -q '"up": *true'; then
		up=1
		break
	fi
	$SLEEP 2
	i=$((i + 2))
done

# --- 12) 結果表示 --------------------------------------------
if [ "$up" = "1" ]; then
	IP=$($UBUS call network.interface.wwan status 2>/dev/null \
		| sed -n 's/.*"address": *"\([0-9.]*\)".*/\1/p' | head -n1)
	log "OK: 学校Wi-Fiに接続しました (IP: ${IP:-取得中})"
else
	warn "wwan が up になりませんでした。次のログを確認してください:"
	$LOGREAD 2>/dev/null | grep -iE 'eap|8021x|802\.1x|deauth|wpa' | tail -n 20
fi

log "--- wifi status ---"
$WIFI status 2>/dev/null | sed 's/^/  /'

[ "$up" = "1" ] || exit 1
exit 0
