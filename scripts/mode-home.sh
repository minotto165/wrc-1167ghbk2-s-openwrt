#!/bin/sh
# 家モード: 上流を PSK の AP に戻す（検証用）
#   HOME_SSID / HOME_PSK を環境変数か /root/home.env で渡す
set -e
[ -f /root/home.env ] && . /root/home.env
: "${HOME_SSID:?HOME_SSID が未設定です}"
: "${HOME_PSK:?HOME_PSK が未設定です}"
say() { echo; echo "===== $* ====="; }

say "1. PSK 設定"
uci set wireless.sta.disabled='0'
uci set wireless.sta.ssid="$HOME_SSID"
uci set wireless.sta.encryption='psk2'
uci set wireless.sta.key="$HOME_PSK"
for k in eap_type auth identity password ca_cert_usesystem ieee80211w; do
    uci -q delete wireless.sta.$k
done
uci commit wireless

say "2. 反映"
wifi reload || true
sleep 20

say "3. 結果"
iw dev phy0-sta0 link 2>&1 | head -5
ifstatus wwan 2>/dev/null | grep -E '"(up|proto)"'
