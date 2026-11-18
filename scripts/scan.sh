#!/bin/sh
# 周囲の AP を調べる（接続前の下見用）
#   phy0-sta0 が上流に使われていても、associated 中なら scan は通る
IF="${1:-phy0-sta0}"
command -v iw >/dev/null || { echo "iw がありません"; exit 1; }
echo "===== $IF でスキャン ====="
iw dev "$IF" scan 2>&1 | grep -E "^BSS|SSID:|freq:|signal:|RSN|EAP" | head -120
echo
echo "===== 学校の SSID を探す ====="
iw dev "$IF" scan 2>&1 | grep -B1 -A2 "School-WiFi" | head -20
