# トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| 再起動で AP が消える | hotplug の `wifi config` が設定を再生成 | `scripts/hotplug-10-wifi-detect.patched` を適用 |
| `radio1` があるのに `phy1` が使われない | `wifi-device` に `option type 'mac80211'` が無い | 追加して `/etc/init.d/network reload` |
| `send failed` / `BEACON-LOSS` / AP の link が上下する | 同一 phy に STA+AP | DBDC で別 phy に分ける |
| `Failed to initiate sched scan` の永久リトライ | mt76 が sched scan を広告するが実行できない | 下記 `disable_scan_offload=1` |
| `iw scan` が `Resource busy (-16)` | スキャン実行中 | 詰まりではない。`iw dev <if> link` を見る |
| 上流は繋がるが通信できない | DHCP 未完了 / NAT 未設定 | `killall udhcpc; ifup wwan` → `fw4 print` |
| `TLS: Certificate verification failed` | RADIUS 証明書が同梱 CA に無い | `ca_cert_usesystem='0'`（暫定）または学認 CA を導入 |
| `CTRL-EVENT-ASSOC-REJECT status_code=17` | PMF / 暗号の不一致 | `ieee80211w='0'` → `2` の順で試す |
| `4-Way Handshake failed` | パスワード・ID 形式の誤り | `DOMAIN\user` / `user@realm` を学校の指示に合わせる |

## `disable_scan_offload=1` の入れ方

`hostapd.sh` が生成する `/var/run/wpa_supplicant-<if>.conf` の先頭に1行足す。

```sh
LN=$(grep -n '_config" <<' /lib/netifd/hostapd.sh | head -1 | cut -d: -f1)
awk -v n="$LN" 'NR==n{print; print "disable_scan_offload=1"; next} {print}' \
	/lib/netifd/hostapd.sh > /tmp/hostapd.sh.new
sh -n /tmp/hostapd.sh.new && cp /tmp/hostapd.sh.new /lib/netifd/hostapd.sh
```

`wpa_supplicant/scan.c:1717` がこのときだけ sched scan を諦める。

```c
if (max_sched_scan_ssids < 1 || wpa_s->conf->disable_scan_offload)
	return -1;
```
