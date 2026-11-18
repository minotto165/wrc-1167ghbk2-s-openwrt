# ソースで確定した仕様（file:line）

このリポジトリの構成は、すべて OpenWrt のソースと実機の両方で裏取りした。
推測で書いた箇所は残していない。

## 無線まわり

### `wifi-device` には `option type 'mac80211'` が必須

`/etc/config/wireless` に手で `config wifi-device 'radio1'` を書いたとき、
`type` を忘れると **netifd はそのセクションを黙って無視する**（`ubus call network.wireless status` にも出ない）。

`wifi config`（`ucode /lib/wifi/mac80211.uc | uci -q batch`）が生成するセクションには必ず入っているので、
手書き・コピペのときだけ踏む。症状は「`phy1` は存在するのに `phy1-ap0` が生えない」。

### DBDC（2ラジオ化）

`drivers/net/wireless/mediatek/mt76/mt7615/eeprom.c:119-140` `mt7615_eeprom_parse_hw_band_cap()`:

| EEPROM の値 | 結果 |
|---|---|
| `MT_EE_5GHZ` | has_5ghz のみ（5GHz 専用） |
| `MT_EE_2GHZ` | has_2ghz のみ |
| `MT_EE_DBDC` | dbdc_support = phy が2つ |
| default | **両バンドを1つの phy で**（この機体はここ） |

`mt7615/debugfs.c:564`:

```c
debugfs_create_file("dbdc", 0600, dir, dev, &fops_dbdc);
```

`mt7615/init.c:527` `mt7615_register_ext_phy()`:

```c
if (!is_mt7615(...)) return -EOPNOTSUPP;
if (test_bit(MT76_STATE_RUNNING, &dev->mphy.state)) return -EINVAL;   /* ← 無線 up 中は無効 */
mt7615_cap_dbdc_enable(dev);
mphy->chainmask = dev->chainmask & ~dev->mphy.chainmask;              /* 4本 → 2+2 */
```

- get は `!!mt7615_ext_phy(dev)` なので `cat` が `1` なら成功
- **`MT76_STATE_RUNNING` 中は `-EINVAL`**。だから `wifi down` してから叩く
- 永続化は `START=95` では遅すぎる（netifd が先に無線を上げてしまう）。**`START=18` にする**

### 同一 phy で STA+AP は壊れる

実機の `iw phy phy0 info`:

```
valid interface combinations:
	 * #{ managed, AP, ... } <= 16, #channels <= 1, STA/AP BI must match
```

`#channels <= 1` のため AP は STA のチャンネルに固定され、実際には
`handle_probe_req: send failed` / link の up-down 反復 / `CTRL-EVENT-BEACON-LOSS` になる。
→ DBDC で phy を分けるのが唯一の解。

### sched scan で永久リトライ

`wpa_supplicant/scan.c:1717`:

```c
if (max_sched_scan_ssids < 1 || wpa_s->conf->disable_scan_offload)
	return -1;
```

mt76 は `max_sched_scan_ssids >= 1` を広告するので supplicant は sched scan を選ぶが、
mt7615 では `NL80211_CMD_START_SCHED_SCAN` が失敗する。`scan.c:1954-1958` は
**通常スキャンにフォールバックせず**状態を戻すだけなので、`Failed to initiate sched scan` が
3秒ごとに永久に出続ける。

回避は生成される supplicant 設定への1行注入（`/lib/netifd/hostapd.sh:1323` の
`cat > "$_config" <<EOF` の直後）:

```sh
disable_scan_offload=1
```

### `wifi detect` は no-op

`package/network/config/wifi-scripts/files/sbin/wifi` の `wifi_detect_notice()`:

```
WARNING: Wifi detect is deprecated. Use wifi config instead
exit 1
```

24.10 も master も同じ。radio を増やす実体は
`/etc/hotplug.d/ieee80211/10-wifi-detect` → `/sbin/wifi config`。

### hotplug が設定を消す

`/etc/hotplug.d/ieee80211/10-wifi-detect`（upstream）:

```sh
[ "${ACTION}" = "add" ] && {
	/sbin/wifi config
}
```

**phy が増えるたび無条件に `wifi config`** する。DBDC で phy1 が生えた瞬間に
`/etc/config/wireless` が再生成され、手で書いた `sta` や AP が消える。
`[ ! -s /etc/config/wireless ]` を足して「設定が空のときだけ生成」にする。

## 802.1X / EAP まわり

### `encryption 'wpa2'` が EAP になる理由

`package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/iface.uc:78-82`:

```ucode
case 'wpa2':
case 'wpa':
case 'wpa-mixed':
	config.auth_type = 'eap';
```

`wpa3` → `eap2`、`wpa3-192` → `eap192`、`wpa3-mixed` → `eap-eap2`。

### `auth` の書き方

`package/network/config/wifi-scripts/files/lib/netifd/hostapd.sh:1519-1524`:

```sh
case "$eap_type" in
fast|peap|ttls)
	json_get_vars auth password ca_cert2 ...
	set_default auth MSCHAPV2
```

`supplicant.uc:164-175`: `auth` が `auth*` で始まれば前置なし、`EAP-*` なら5文字目以降を採用し、
**TTLS のときだけ `autheap=`** になる。

→ `option auth 'MSCHAPV2'` と `option auth 'EAP-MSCHAPV2'` は同じ結果。

### `ca_cert_usesystem`

`hostapd.sh:1472-1482`:

```sh
json_get_vars eap_type identity anonymous_identity ca_cert ca_cert_usesystem
...
[ "$ca_cert_usesystem" = 1 ] && ca_cert="/etc/ssl/certs/ca-certificates.crt"
```

`/etc/ssl/certs/ca-certificates.crt` が実在することが前提（24.10 でも効く。実測 180,744B）。
`ca_cert` を明示した場合は `ca_cert_usesystem` を 0 にしないと上書きされる。

### 生成される設定ファイルの実物

`/var/run/wpa_supplicant-phy0-sta0.conf`:

```
disable_scan_offload=1          ← 注入した行


country=JP
network={
        scan_ssid=1
        ssid="School-WiFi"
        key_mgmt=WPA-EAP WPA-EAP-SHA256
        ca_cert="/etc/ssl/certs/ca-certificates.crt"
        identity="your-id"
        password="..."
        phase2="auth=MSCHAPV2"
        eap=PEAP
        proto=RSN
        ieee80211w=1
        beacon_int=100
}
```

`key_mgmt` に `WPA-EAP-SHA256` が併記されるが、AP が WPA2 なら `WPA-EAP` で成立する。

## ツールまわりの罠

| 罠 | 内容 |
|---|---|
| busybox に `diff` が無い | 比較は `md5sum` か `cmp`（`cmp` も無い場合あり） |
| busybox の `ip` は `-br` 非対応 | `ip link show <if>` を使う |
| heredoc にタブを入れる | ash の行編集（補完）が発動して壊れる。**インデントはスペース** |
| `wifi detect` | 廃止済み。何も起きない |
| `iw dev <if> scan` の `Resource busy (-16)` | スキャン実行中。詰まりとは限らない |
| `scp` | OpenSSH 9 は `scp -O` か `cat | ssh` |
