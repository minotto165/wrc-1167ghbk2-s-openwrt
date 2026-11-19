#!/bin/sh
# 学校モード: 上流(radio0=2.4GHz) を WPA2-Enterprise に切り替える
#
#   1) cp school.env.example /root/school.env && vi /root/school.env
#   2) sh /root/mode-school.sh
#
# 事前に DBDC（phy0/phy1 の2ラジオ）が有効であること。
set -e

[ -f /root/school.env ] && . /root/school.env

: "${SCHOOL_SSID:?SCHOOL_SSID が未設定です（/root/school.env）}"
: "${EAP_IDENTITY:?EAP_IDENTITY が未設定です（/root/school.env）}"
: "${EAP_PASSWORD:?EAP_PASSWORD が未設定です（/root/school.env）}"
EAP_TYPE="${EAP_TYPE:-peap}"
EAP_AUTH="${EAP_AUTH-MSCHAPV2}"
STA_BAND="${STA_BAND:-5g}"
# 1 = サーバ証明書を検証する（学校の CA と domain が要る）
# 0 = 検証しない。私有 CA の学校では mbedtls がホスト名を要求して失敗するため既定は 0
CA_VERIFY="${CA_VERIFY:-0}"

say() { echo; echo "===== $* ====="; }

say "0. 前提チェック"
ls /sys/class/ieee80211/ | tr '\n' ' '; echo " <- phy（2つ必要）"
ps w | grep -q 'wpa_supplicant' && echo "wpa_supplicant: ok"
if wpad_bin=$(command -v wpad); then :; fi
if [ -x /usr/sbin/wpa_supplicant ]; then
    /usr/sbin/wpa_supplicant -v 2>/dev/null | head -1
fi
# STA と AP は別の phy に置く。同じ phy に同居させると送信が壊れる
if [ "$STA_BAND" = "5g" ]; then
    uci set wireless.sta.device='radio1'
    uci set wireless.default_radio1.device='radio0'
else
    uci set wireless.sta.device='radio0'
    uci set wireless.default_radio1.device='radio1'
fi

say "1. EAP 設定"
uci set wireless.sta.disabled='0'
uci set wireless.sta.mode='sta'
uci set wireless.sta.network='wwan'
uci set wireless.sta.ssid="$SCHOOL_SSID"
uci set wireless.sta.encryption='wpa2'
uci set wireless.sta.eap_type="$EAP_TYPE"
if [ -n "${EAP_AUTH}" ]; then
    uci set wireless.sta.auth="$EAP_AUTH"
else
    uci -q delete wireless.sta.auth
fi
uci set wireless.sta.identity="$EAP_IDENTITY"
uci set wireless.sta.password="$EAP_PASSWORD"
uci set wireless.sta.ca_cert_usesystem="$CA_VERIFY"
uci set wireless.sta.ieee80211w='1'
uci -q delete wireless.sta.key
uci commit wireless

say "2. 反映"
wifi reload || true
sleep 25

say "3. 結果"
iw dev | grep -E "Interface|type|ssid|channel"
echo "--- link ---"
iw dev phy0-sta0 link 2>&1 | head -6
echo "--- wwan ---"
ifstatus wwan 2>/dev/null | grep -E '"(up|proto|l3_device|address)"'
echo "--- log ---"
logread | grep -E 'wpa_supplicant|wpad' | tail -25

cat <<'HINT'

うまくいかないときは上記ログの末尾を見る:
  TLS: Certificate verification failed  -> uci set wireless.sta.ca_cert_usesystem='0'
  CTRL-EVENT-ASSOC-REJECT status_code=17 -> uci set wireless.sta.ieee80211w='0'
  4-Way Handshake failed                 -> identity/password の形式を確認
HINT
