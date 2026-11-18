#!/bin/sh
# セットアップ後の状態ダンプ。動かないときに これを実行して出力を貼る。
echo "===== wireless ====="
uci show wireless 2>/dev/null

echo "===== network(wwan) ====="
uci show network 2>/dev/null | grep -i wwan

echo "===== firewall(wan zone) ====="
uci show firewall 2>/dev/null | grep -E "\.network=|\.masq="

echo "===== radios (regdom) ====="
iw reg get 2>/dev/null
iw dev 2>/dev/null

echo "===== wwan status ====="
ifstatus wwan 2>/dev/null || ubus call network.interface.wwan status 2>/dev/null

echo "===== stations / AP ====="
iw dev 2>/dev/null | grep -A4 -i "station\|type"

echo "===== ip ====="
ip -4 addr show 2>/dev/null

echo "===== wpad / packages ====="
apk info 2>/dev/null | grep -i wpad
[ -x /usr/sbin/wpa_supplicant ] && wpa_supplicant -v 2>/dev/null

echo "===== log (1X / EAP) ====="
logread 2>/dev/null | grep -iE 'eap|8021x|802\.1x|deauth|wpa_suppl|hostapd' | tail -n 40
