# 導入（純正ファーム → OpenWrt）

## 1. イメージを用意する

### 素直な方法: Firmware Selector

https://firmware-selector.openwrt.org/?version=24.10.8&target=ramips%2Fmt7621&id=elecom_wrc-1167ghbk2-s

「カスタマイズ」を開いてパッケージを編集する。**`wpad-basic-mbedtls` は EAP 非対応**なので必ず差し替える。

```
... 既定一式 ...
wpad-mbedtls          ← wpad-basic-mbedtls を消して追加
luci                  ← GUI が欲しければ
```

`#uci-defaults-content` に初回起動スクリプトを入れられる（有線が無い環境では必須。後述）。

### ASU（attended-sysupgrade）でのビルド結果

このリポジトリの作業で実際に使ったビルド:

| 項目 | 値 |
|---|---|
| バージョン | 24.10.8 |
| store hash | `ab00319cc7842fcd8d82b34adb0123d98f94c0115c200238c0d3ca3e1f1c59a7` |
| image prefix | `ab11203c9990` |
| sysupgrade | `openwrt-24.10.8-ab11203c9990-ramips-mt7621-elecom_wrc-1167ghbk2-s-squashfs-sysupgrade.bin` |
| sha256 | `5cb0f8476bce3584a60fae4122de215cc5452c89d141af956d91e675cefaee3b` |
| 同梱 | `wpad-mbedtls`（wpad-basic なし）、`kmod-mt7615e/common/firmware`、全144パッケージ |

ビルド記録は `https://sysupgrade.openwrt.org/api/v1/build/<store hash>` で JSON として取れる
（`request.packages` / `manifest` / `stdout` / `file_size_limits` が入っている）。

## 2. イメージの構造（factory と sysupgrade）

`target/linux/ramips/image/mt7621.mk`:

```make
define Device/elecom_wrc-1167ghbk2-s
  IMAGE_SIZE := 15488k
  DEVICE_PACKAGES := kmod-mt7615-firmware -uboot-envtools
  IMAGES := factory.bin sysupgrade.bin
  IMAGE/factory.bin := $$(sysupgrade_bin) | check-size | elecom-wrc-gs-factory WRC-1167GHBK2-S 0.00
```

`include/image-commands.mk` の `Build/elecom-wrc-gs-factory` が

```
[ md5(body) 32バイト ][ "ELECOM <product> v<version>" を 32バイトに NUL 詰め ][ body ]
```

を作る。実物でも先頭32バイトは `ELECOM WRC-1167GHBK2-S v0.00`、末尾は md5 32文字 + 改行（33バイト）。
純正に戻すときはこの 32 + 33 バイトを剥がす。

## 3. 書き込み

1. 純正ファームで有線接続し `http://192.168.2.1/details.html`
2. 管理アカウントを作る（ユーザー名は `admin` 固定、パスワードは自由）
3. 「ファームウェア手動更新」で **factory イメージ**を選ぶ
4. **ファイル名を `wrc-1167ghbk2-s_v0.00.bin` にリネームしておく**（純正 UI がファイル名を検査する）
5. 更新実行 → 残り時間表示 → 最後に Wi-Fi/HTTP が切れる → 3〜5分待つ
6. OpenWrt が `192.168.1.1` で起動

### 初回のログイン

```sh
ssh root@192.168.1.1      # パスワードは空（Enter）
```

`scp` は OpenSSH 9 の既定（SFTP）だと `ash: /usr/libexec/sftp-server: not found` で失敗する。

```sh
scp -O file.bin root@192.168.1.1:/tmp/          # 旧プロトコル
cat file.bin | ssh root@192.168.1.1 'cat > /tmp/file.bin'
```

## 4. 初回起動で AP を点ける（有線が無い場合）

OpenWrt の既定では **Wi-Fi は無効**（`mac80211.uc` が `disabled='1'` を書く）。
有線が使えない環境では `#uci-defaults-content` に以下を入れておくと、初回起動で 2.4GHz AP が点く。

```sh
#!/bin/sh
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
		uci -q set wireless.$ifc.disabled='0'
		uci -q set wireless.$ifc.ssid='OpenWrt-Setup'
		uci -q set wireless.$ifc.encryption='psk2'
		uci -q set wireless.$ifc.key='openwrt1234'
	done
	uci -q commit wireless
fi
wifi up >/dev/null 2>&1
exit 0
```

このスクリプトは失敗しても無言で `exit 0` する。成功条件は「ある瞬間に `band='2g'` の
wifi-device が存在すること」の1点だけで、phy の登録が遅い・5GHz だけ先に出る・
`board.json` に `wlan` が無い、といった場合に静かに空振りする。
実際、この書き方で一度「起動はするが SSID が一切出ない」状態になった。

→ 有線で入れるなら、このスクリプトには頼らず手で設定するのが確実。

## 5. 復旧

| 手段 | 手順 |
|---|---|
| 有線 + 192.168.1.1 | 最も簡単。LuCI / ssh で入って直す |
| failsafe | 起動直後にリセットボタンを押し続ける（`led-failsafe`） |
| UART | 57600 8N1 / 3.3V / GND-TX-RX の3本。u-boot を止めて TFTP |
| 純正に戻す | 上記のヘッダ剥がし + `mtd -r write` |
