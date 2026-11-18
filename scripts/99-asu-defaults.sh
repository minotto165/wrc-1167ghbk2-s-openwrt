#!/bin/sh
# first boot: enable 2.4GHz AP so LuCI is reachable without ethernet
i=0
while [ $i -lt 20 ] && [ ! -d /sys/class/ieee80211/phy0 ]; do i=$((i+1)); sleep 1; done

i=0
while [ $i -lt 10 ] && ! uci -q show wireless 2>/dev/null | grep -q "\.mode='ap'"; do
	wifi config >/dev/null 2>&1
	i=$((i+1)); sleep 1
done

dev=$(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)\.band='2g'/\1/p" | head -1)
if [ -n "$dev" ]; then
	uci -q set wireless.$dev.disabled='0'
	uci -q set wireless.$dev.country='JP'
	for ifc in $(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)\.device='$dev'/\1/p"); do
		[ "$(uci -q get wireless.$ifc.mode)" = "ap" ] || continue
		uci -q set wireless.$ifc.disabled='0'
		uci -q set wireless.$ifc.ssid='OpenWrt-Setup'
		uci -q set wireless.$ifc.encryption='psk2'
		uci -q set wireless.$ifc.key='openwrt1234'
	done
	uci -q commit wireless
else
	echo "99-asu-defaults: 2.4GHz ラジオが見つかりません。有線で 192.168.1.1 に入ってください" >&2
fi
wifi up >/dev/null 2>&1
exit 0
