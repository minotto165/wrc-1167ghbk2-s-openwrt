# ELECOM WRC-1167GHBK2-S を OpenWrt で「WPA2-Enterprise クライアント + 自前AP」にする

学校 Wi-Fi（WPA2-Enterprise / PEAP-MSCHAPv2）に **ルーター自身がクライアントとしてログイン**し、
その回線を **自分専用の SSID** として再放出するための、実機で最後まで通した構成の記録。

```
        ┌─────────────── WRC-1167GHBK2-S (OpenWrt 24.10.8) ───────────────┐
学校Wi-Fi ─2.4GHz→ phy0-sta0 ─NAT→ br-lan ─→ phy1-ap0 ─5GHz→ 自分の端末
 (EAP)         wwan(DHCP)      fw4 masq        MyRouter / ch36 / 80MHz
        └─────────────────────────────────────────────────────────────────┘
```

- 上流（クライアント）: `radio0` = MT7615D の 2.4GHz 側 → 学校の SSID に EAP 接続
- 下流（AP）: `radio1` = MT7615D の 5GHz 側 → `MyRouter` (WPA2-PSK) を再放出
- 端末から見ると普通の Wi-Fi ルーター。学校から見ると「1台の端末が EAP 認証した」だけ。

## 実績（このリポジトリの構成で確認済み）

| 項目 | 結果 |
|---|---|
| 純正ファーム → OpenWrt 24.10.8 | 純正 Web UI から書き込み成功 |
| DBDC 有効化（2.4G/5G 同時） | `phy0` + `phy1` の2ラジオで動作 |
| 上流 STA 接続（PSK 検証） | 接続 → DHCP → ping 0% loss |
| 下流 AP 再放出 | `phy1-ap0` AP-ENABLED / ch36 / 80MHz |
| 端末 → インターネット | `curl https://www.google.com` → **200** |
| 再起動後の自動復帰 | 設定・DBDC・AP・上流すべて復帰 |

## ハードウェア

| 項目 | 値 |
|---|---|
| SoC | MediaTek MT7621A（2C4T / 880MHz） |
| RAM | 128MB |
| Flash | SPI 16MB（firmware パーティション 0xf20000） |
| 無線 | **MT7615D 1チップ**（DBDC で 2.4G + 5G の2ラジオに分割可能） |
| 有線 | WAN 1 + LAN 4（GbE） |
| シリアル | 57600bps 8N1（基板上パッド、GND/TX/RX の3本） |
| 対応イメージ | `ramips/mt7621` / `elecom_wrc-1167ghbk2-s` |

## なぜ 24.10.8 なのか（25.12 で踏んだ地雷）

OpenWrt 25.12.6 では `wpa_supplicant`（wpad）が **nl80211 の初期化でつまずき、スキャンを一切発行しない**まま
`Set new config for phy phy0` だけを吐いて沈黙する。`iw` による手動スキャンは同じ phy で成功するので
ドライバ・ファーム・DFS はシロ、**wpad 側の経路だけが壊れている**と切り分け済み。

24.10.8 でも wpad は ubus 経由のグローバル制御IF方式（`-n -s -g /var/run/wpa_supplicant/global`）だが、
24.10.8 では **AP モード（hostapd）も STA モード（wpa_supplicant）も動作**することを実機で確認した。

さらに 25.12 系では mt76 が sched scan を広告するのに実行は失敗し、
`Failed to initiate sched scan` を3秒ごとに永久リトライする症状も出る（→ 下記 `disable_scan_offload`）。

## なぜ DBDC が必須なのか

MT7615D は 1チップだが、OpenWrt の既定では **1つの phy が 2.4GHz と 5GHz の両方を持つ**状態で登録される
（`mt7615_eeprom_parse_hw_band_cap()` の `default:` 分岐 = 両バンド・DBDC なし）。

この状態で同じ phy に STA と AP を同居させると、実機では **送信が破綻**する:

```
hostapd: handle_probe_req: send failed
netifd: Network device 'phy0-ap0' link is up → down → up を反復
wpa_supplicant: phy0-sta0: CTRL-EVENT-BEACON-LOSS
iw phy phy0 info: #{ managed, AP, ... } <= 16, #channels <= 1, STA/AP BI must match
```

`#channels <= 1` が効いていて、AP は STA のチャンネルに縛られる。だから **DBDC で phy を2つに割る**。

DBDC 有効化は debugfs の1行:

```sh
echo 1 > /sys/kernel/debug/ieee80211/phy0/mt76/dbdc
```

ただし **実行時設定なのでリブートで消える**。`/etc/init.d/dbdc`（START=18）で起動時に毎回叩く。

## セットアップ手順

### 0. 準備

- 有線で作業する PC（初回だけ必須）
- ダウンロード: [Firmware Selector](https://firmware-selector.openwrt.org/?version=24.10.8&target=ramips%2Fmt7621&id=elecom_wrc-1167ghbk2-s)
  - カスタマイズで `wpad-basic-mbedtls` を消し **`wpad-mbedtls`** を入れる（EAP 非対応のため必須）
  - 追加で `luci`（GUI が欲しければ）

### 1. 純正 → OpenWrt

1. 純正ファームで `http://192.168.2.1/details.html` を開く（管理アカウント作成 → 詳細設定）
2. ファームウェア手動更新で **factory イメージを選択**
3. 純正 UI はファイル名を検査するので **`wrc-1167ghbk2-s_v0.00.bin` にリネーム**してから選ぶ
4. 更新実行 → 3〜5分 → OpenWrt が `192.168.1.1` で起動
5. 有線で `ssh root@192.168.1.1`（初回はパスワード空）

> リネームが必要な理由: 純正 UI が `WRC-1167GHBK2-S` の文字列をファイル名に要求するため。
> factory イメージ先頭32バイトは `ELECOM WRC-1167GHBK2-S v0.00`（`include/image-commands.mk` の
> `Build/elecom-wrc-gs-factory`）で、末尾33バイトは md5 + 改行。

### 2. DBDC を有効化する

```sh
uci set wireless.sta.disabled='1'      # いったん無線を落ち着かせる
wifi down; sleep 2
mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug
echo 1 > /sys/kernel/debug/ieee80211/phy0/mt76/dbdc
cat /sys/kernel/debug/ieee80211/phy0/mt76/dbdc     # → 1
wifi config                                        # phy1 を見つけて radio1 を作る
```

`wifi config` が作る `radio1` は **`disabled='1'`** なので有効化する:

```sh
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.type='mac80211'    # ★ これが無いと netifd は黙って無視する
uci commit wireless
```

### 3. 上流（学校 Wi-Fi）に EAP で接続

`/etc/config/network`:

```
config interface 'wwan'
	option proto 'dhcp'
```

`/etc/config/wireless`（追記）:

```
config wifi-device 'radio0'
	option type 'mac80211'
	option path '1e140000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0'
	option band '2g'
	option channel 'auto'
	option htmode 'HT20'
	option country 'JP'
	option disabled '0'

config wifi-iface 'sta'
	option device 'radio0'
	option mode 'sta'
	option network 'wwan'
	option ssid 'School-WiFi'
	option encryption 'wpa2'
	option eap_type 'peap'
	option auth 'MSCHAPV2'
	option identity 'your-id'
	option password '<学校パスワード>'
	option ca_cert_usesystem '1'
	option ieee80211w '1'
```

| オプション | 意味 |
|---|---|
| `encryption 'wpa2'` | STA では内部で `auth_type=eap` に変換される（`wpa3` → eap2） |
| `eap_type 'peap'` | `ttls` / `tls` / `fast` も可 |
| `auth 'MSCHAPV2'` | `EAP-MSCHAPV2` と書いても同じ（TTLS のときだけ `autheap=` になる） |
| `ca_cert_usesystem '1'` | `/etc/ssl/certs/ca-certificates.crt` を自動で CA に使う |
| `ieee80211w '1'` | PMF optional。学校が PMF 必須なら `2`、不要なら `0` |

適用:

```sh
uci commit wireless network
wifi reload
sleep 25
iw dev phy0-sta0 link
ifstatus wwan | grep -E '"(up|proto)"'
```

### 4. 下流 AP を再放出

```
config wifi-device 'radio1'
	option type 'mac80211'
	option path '1e140000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0+1'
	option band '5g'
	option channel '36'
	option htmode 'VHT80'
	option country 'JP'
	option disabled '0'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option mode 'ap'
	option network 'lan'
	option ssid 'MyRouter'
	option encryption 'psk2'
	option key '<好きなパスワード>'
```

> `+1` は2つ目の phy を指す OpenWrt のパス表記。
> `readlink -f /sys/class/ieee80211/phy{0,1}/device` が同じパスを返すのが正常。

### 5. NAT で通す

`wwan` を wan ゾーンに入れるだけ（fw4 は `masq` 済み）:

```sh
uci add_list firewall.@zone[1].network='wwan'
uci commit firewall
/etc/init.d/firewall restart
fw4 print | grep -A6 "chain nat_postrouting"
```

### 6. 再起動に耐えるようにする（2ファイル）

**① DBDC を起動時に有効化** → `scripts/init.d-dbdc` を `/etc/init.d/dbdc` に置いて `enable`。
START=18 は `wpad`(19) / `network`(20) より前でないと意味がない。

**② hotplug が設定を消すのを止める** → `/etc/hotplug.d/ieee80211/10-wifi-detect`

upstream はこうなっている:

```sh
[ "${ACTION}" = "add" ] && {
	/sbin/wifi config
}
```

phy が増えるたび **無条件で `wifi config`** するので、DBDC で phy1 が生えた瞬間に
`/etc/config/wireless` が再生成され、`sta` も AP も消える。**これが「再起動で MyRouter が消える」の正体。**

```sh
[ "${ACTION}" = "add" ] && [ ! -s /etc/config/wireless ] && {
    /sbin/wifi config
}
```

`scripts/hotplug-10-wifi-detect.patched` を参照。

### 7. 検証

```sh
ls /sys/class/ieee80211/                 # phy0 phy1
iw dev | grep -E "Interface|ssid|channel"
iw dev phy0-sta0 link                    # 上流に接続済みか
ifstatus wwan | grep '"up"'              # true か
ping -c 2 8.8.8.8
```

端末を `MyRouter` に繋いで `curl -s -o /dev/null -w '%{http_code}' https://www.google.com` → `200`。

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| 再起動で AP が消える | hotplug の `wifi config` が設定を再生成 | 手順6②のパッチ |
| `radio1` があるのに `phy1` が使われない | `wifi-device` に **`option type 'mac80211'` が無い** | 追加して `network reload` |
| `send failed` / `BEACON-LOSS` / AP の link が上下する | 同一 phy に STA+AP | DBDC を有効化して別 phy に分ける |
| `Failed to initiate sched scan` の永久リトライ | mt76 が sched scan を広告するが実行できない | `disable_scan_offload=1` を注入（下記） |
| `iw scan` が `Resource busy (-16)` | スキャン実行中 | 詰まりではない。まず `iw dev <if> link` を見る |
| 上流は繋がるが通信できない | DHCP 未完了 / NAT 未設定 | `killall udhcpc; ifup wwan` → `fw4 print` |
| `TLS: Certificate verification failed` | RADIUS 証明書が同梱 CA に無い | `ca_cert_usesystem='0'`（暫定）または学認 CA を `/etc/ssl/certs` へ |
| `CTRL-EVENT-ASSOC-REJECT status_code=17` | PMF / 暗号の不一致 | `ieee80211w='0'` → `2` の順で試す |
| `4-Way Handshake failed` | パスワード・ID 形式の誤り | `DOMAIN\user` / `user@realm` を学校の指示に合わせる |

### `disable_scan_offload=1` の入れ方

`hostapd.sh` が生成する `/var/run/wpa_supplicant-<if>.conf` の先頭に1行足す:

```sh
LN=$(grep -n '_config" <<' /lib/netifd/hostapd.sh | head -1 | cut -d: -f1)
awk -v n="$LN" 'NR==n{print; print "disable_scan_offload=1"; next} {print}' \
	/lib/netifd/hostapd.sh > /tmp/hostapd.sh.new
sh -n /tmp/hostapd.sh.new && cp /tmp/hostapd.sh.new /lib/netifd/hostapd.sh
```

`wpa_supplicant/scan.c:1717`:

```c
if (max_sched_scan_ssids < 1 || wpa_s->conf->disable_scan_offload)
	return -1;
```

## 純正ファームに戻す

純正 .bin から**先頭32バイト**（`ELECOM WRC-1167GHBK2-S vX.XX` を NUL 詰め）と
**末尾33バイト**（md5 32文字 + 改行）を剥がして firmware パーティションへ:

```sh
python3 - <<'PY'
d = open('wrc-1167ghbk2-s.bin','rb').read()
open('/tmp/stock.bin','wb').write(d[32:-33])
PY
mtd -r write /tmp/stock.bin firmware
```

UART（57600 8N1 / 3.3V / GND-TX-RX のみ）から u-boot で TFTP 復旧も可能。

## ファイル

```
docs/
  verification-source.md   ソースコードでの裏取り（hostapd/wifi-scripts/mt76）
  verification-harness.md  モックテスト 181 ケースの結果
  verification-emul.md     本物の uci/ash を qemu で動かした検証
scripts/
  setup.sh                 EAP + AP + NAT を一括設定（実 uci で検証済み）
  mode-school.sh           学校モードへ切替
  mode-home.sh             家モードへ戻す
  scan.sh                  周囲の AP を調べる
  diagnose.sh              状態ダンプ
  init.d-dbdc              DBDC の起動時有効化
  hotplug-10-wifi-detect.patched  設定を守る hotplug
  99-asu-defaults.sh       初回起動で AP を点灯させる uci-defaults
  school.env.example       学校の資格情報のテンプレート
tools/                     検証用ハーネス（mock uci / Docker+qemu）
```

## 注意

- **学校のネットワーク利用規約を確認すること。** 私的ルーターの接続・再放出を禁じている場合がある。
- 検知されうる要素: MAC 登録制、1端末1認証、TTL/ホップ数の検査、DHCP フィンガープリント、同時接続数。
  NAT 構成は「1台の端末」に見えるが、**規約上の可否は別問題**。
- `ca_cert_usesystem='0'` は中間者攻撃に無防備になる。恒久対処は学校の CA 証明書を入れること。
- 資格情報はこのリポジトリに含めない（`school.env` は `.gitignore` 済み）。
