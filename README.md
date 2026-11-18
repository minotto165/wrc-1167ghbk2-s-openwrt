# ELECOM WRC-1167GHBK2-S を OpenWrt で「WPA2-Enterprise クライアント + 自前AP」にする

学校 Wi-Fi（WPA2-Enterprise / PEAP-MSCHAPv2）にルーター自身がクライアントとしてログインし、
その回線を自分専用の SSID として再放出する。実機で最後まで通した構成の記録。

```
        ┌─────────────── WRC-1167GHBK2-S (OpenWrt 24.10.8) ───────────────┐
学校Wi-Fi ─2.4GHz→ phy0-sta0 ─NAT→ br-lan ─→ phy1-ap0 ─5GHz→ 自分の端末
 (EAP)         wwan(DHCP)      fw4 masq        MyRouter / ch36 / 80MHz
        └─────────────────────────────────────────────────────────────────┘
```

## 構成

本体は MT7621A（RAM 128MB / Flash 16MB / **MT7615D 1チップ**）。
上流を `radio0`、下流を `radio1` に割り当て、`wwan` を wan ゾーンに入れて NAT で再放出する。
学校から見ると「1台の端末が EAP 認証した」だけになる。

## 実績

| 項目 | 結果 |
|---|---|
| 純正ファーム → OpenWrt 24.10.8 | 純正 Web UI から書き込み成功 |
| DBDC 有効化（2.4G/5G 同時） | `phy0` + `phy1` の2ラジオで動作 |
| 上流 STA 接続（PSK 検証） | 接続 → DHCP → ping 0% loss |
| 下流 AP 再放出 | `phy1-ap0` AP-ENABLED / ch36 / 80MHz |
| 端末 → インターネット | `curl https://www.google.com` → `200` |
| 再起動後の自動復帰 | 設定・DBDC・AP・上流すべて復帰 |
| DoH（配下の全端末） | 外向き53を落としても名前解決（[docs/04-doh.md](docs/04-doh.md)） |

## 手順

### 0. 準備

- 有線で作業する PC（初回だけ必要）
- [Firmware Selector](https://firmware-selector.openwrt.org/?version=24.10.8&target=ramips%2Fmt7621&id=elecom_wrc-1167ghbk2-s) で
  `wpad-basic-mbedtls` を消し **`wpad-mbedtls`** を入れる（EAP 非対応のため必須）

### 1. 純正 → OpenWrt

1. 純正ファームで `http://192.168.2.1/details.html`（管理アカウント作成 → 詳細設定）
2. 「ファームウェア手動更新」で factory イメージ。**`wrc-1167ghbk2-s_v0.00.bin` にリネーム必須**（純正 UI がファイル名を検査する）
3. 更新実行 → 3〜5分 → `192.168.1.1` で起動
4. `ssh root@192.168.1.1`（パスワードは空）

詳細と復旧手段は [docs/01-flash.md](docs/01-flash.md)。

### 2. DBDC を有効化する

MT7615D は既定だと1つの phy が両バンドを持ち、同じ phy に STA と AP を同居させると送信が破綻する。
DBDC で phy を2つに割る。

```sh
wifi down; sleep 2
mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug
echo 1 > /sys/kernel/debug/ieee80211/phy0/mt76/dbdc
cat /sys/kernel/debug/ieee80211/phy0/mt76/dbdc     # → 1
wifi config                                        # phy1 を見つけて radio1 を作る

uci set wireless.radio1.disabled='0'               # 生成時は disabled='1'
uci set wireless.radio1.type='mac80211'            # 無いと netifd は黙って無視する
uci commit wireless
```

経緯は [docs/03-debug-log.md](docs/03-debug-log.md)（第4の壁）。

### 3. 上流（学校 Wi-Fi）に EAP で接続

`/etc/config/network`:

```
config interface 'wwan'
	option proto 'dhcp'
```

`/etc/config/wireless`:

```
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
| `auth 'MSCHAPV2'` | `EAP-MSCHAPV2` と書いても同じ（TTLS のときだけ `autheap=` になる） |
| `ca_cert_usesystem '1'` | `/etc/ssl/certs/ca-certificates.crt` を自動で CA に使う |
| `ieee80211w '1'` | PMF optional。学校が必須なら `2`、不要なら `0` |

```sh
uci commit wireless network
wifi reload
sleep 25
iw dev phy0-sta0 link
ifstatus wwan | grep -E '"(up|proto)"'
```

### 4. 下流 AP を再放出

```
config wifi-iface 'default_radio1'
	option device 'radio1'
	option mode 'ap'
	option network 'lan'
	option ssid 'MyRouter'
	option encryption 'psk2'
	option key '<好きなパスワード>'
```

`radio1` の `path` は `...0000:01:00.0+1`（`+1` が2つ目の phy）。

### 5. NAT で通す

`wwan` を wan ゾーンに入れるだけ。fw4 の `masq` は既に有効。

```sh
uci add_list firewall.@zone[1].network='wwan'
uci commit firewall
/etc/init.d/firewall restart
```

### 6. 再起動に耐えるようにする（2ファイル）

**① DBDC を起動時に有効化** — `scripts/init.d-dbdc` を `/etc/init.d/dbdc` に置いて `enable`。
START=18 は `wpad`(19) / `network`(20) より前でないと意味がない。

**② hotplug が設定を消すのを止める** — `/etc/hotplug.d/ieee80211/10-wifi-detect` は phy が増えるたび
無条件で `wifi config` するため、DBDC で phy1 が生えた瞬間に設定が再生成される。

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
```

端末を `MyRouter` に繋いで `curl -s -o /dev/null -w '%{http_code}' https://www.google.com` → `200`。
学内では ICMP が遮断されるので `ping` は通らない。

### 8. （任意）配下の端末を DoH にする

学校の DNS フィルタを回避したい場合だけ。ルーター1台で全端末に効く。

```sh
opkg update && opkg install https-dns-proxy
```

設定・検証・戻し方は [docs/04-doh.md](docs/04-doh.md)。

## トラブルシュート

症状別の対処は [docs/05-troubleshooting.md](docs/05-troubleshooting.md)。

## 純正ファームに戻す

純正 .bin から先頭32バイト（`ELECOM WRC-1167GHBK2-S vX.XX` を NUL 詰め）と末尾33バイト（md5 + 改行）を剥がす。

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
  01-flash.md              書き込みと復旧
  02-findings.md           ソースでの裏取り（file:line 付き）
  03-debug-log.md          5つの壁の時系列記録
  04-doh.md                配下の端末を DoH にする
  05-troubleshooting.md    症状別の対処
  verification-*.md        検証レポート（ソース / ハーネス / エミュレータ）
scripts/
  setup.sh                 EAP + AP + NAT を一括設定
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

- 学校のネットワーク利用規約を確認すること。私的ルーターの接続・再放出を禁じている場合がある。
- 検知されうる要素: MAC 登録制、1端末1認証、TTL/ホップ数の検査、DHCP フィンガープリント、同時接続数。
- `ca_cert_usesystem='0'` は中間者攻撃に無防備になる。恒久対処は学校の CA 証明書を入れること。
- 資格情報はこのリポジトリに含めない（`school.env` は `.gitignore` 済み）。
