# デバッグ記録（時系列）

同じ構成を作り直す人が同じ穴に落ちないように、詰まった順に残す。

## 前提

- Mac（作業機）は学校 Wi-Fi に接続中。**有線ポートが無い**
- ルーターには手が届かない位置にある（電源の抜き差しも不可）
- そのため「初回起動で AP を点ける uci-defaults 入りイメージ」を ASU でビルドして焼いた

## 第1の壁: 焼いたのに SSID が一切出ない

症状:

- 純正の SSID も消え、OpenWrt の SSID も出ない
- 電源 LED は ピンク → 緑点滅 → 緑点灯 で止まる（＝起動完了）

LED の意味（`package/base-files/files/etc/diag.sh` の `set_led_state()`）:

| 状態 | 意味 |
|---|---|
| ピンク | 赤(GPIO16)+青(GPIO8) がまだ Linux に掴まれていない = u-boot |
| 緑点滅 | `preinit`（`/etc/init.d/boot` が走っている） |
| 緑点灯 | `done`（START=95）まで到達 = **完全起動** |

→ 起動はしている。無線だけが上がっていない。

原因は uci-defaults スクリプトの「失敗しても何も出力せずに `exit 0`」設計。
`board.json` に `wlan` が無い・phy の登録が30秒を超える・5GHz だけ先に出る、のいずれでも静かに空振りする。

なお `wlan2g` LED は `linux,default-trigger = "phy0radio"` なので、
**この LED が点いていれば phy0 の radio は up** という目視判定に使える（`wlan5g` は trigger 無しで常に消灯）。

## 第2の壁: 有線で入っても STA が繋がらない

`iw dev` に `phy0-sta0`（managed）はあるが `ssid` が無く、`iw dev phy0-sta0 scan` は `Resource busy (-16)`。

確定した事実:

- `logread` に `CTRL-EVENT-SCAN-STARTED` / `SCAN-RESULTS` / `SME: Trying to authenticate` が**1行も無い**
- つまり **スキャンが一度も走っていない**。EAP の資格情報以前の問題
- カーネルの `rdev->scan_req` が残っている＝スキャン要求が返ってきていない

決定的な切り分け:

```sh
uci set wireless.sta.disabled='1'; reboot
iw phy phy0 interface add t1 type managed
ip link set t1 up
iw dev t1 scan                      # → 成功（近隣APが見える）
iw dev t1 scan ssid <学校SSID>       # → 成功
```

ドライバ・ファーム・DFS は問題なく、wpa_supplicant 経由のときだけ壊れる。

手動で wpa_supplicant を起こすと:

```
Successfully initialized wpa_supplicant
t1: nl80211: kernel reports: Match already configured   ← ×24
t1: CTRL-EVENT-DSCP-POLICY clear_all
nl80211: deinit ifname=t1 disabled_11b_rates=0
```

`Set mode ifindex ... iftype 2 (STATION)` も `Scan trigger` も出ない。
→ **ドライバとのハンドシェイク前に終わっている。**

（`ctrl_interface` を既存の wpad と衝突させると
`Failed to initialize control interface` で即 exit 255 になるので、テスト時は別ディレクトリにする）

補足: OpenWrt の wpad は `-n`（ubus モード）で動いており、
netifd 管理下でないインターフェースを渡すと `no PHY for ifname t1` になる。
**手作りインターフェースでのテストは無効**なので、netifd 管理下で
「存在しない SSID」「`encryption none`」を試す。結果は同じく無言 → ネットワーク種別は無関係と確定。

## 第3の壁: 24.10 に落としても同じ

25.12.6 → 24.10.8 に sysupgrade しても症状は同一。24.10 も wpad は
`-n -s -g /var/run/wpa_supplicant/global` の ubus 方式で、生成される
`/var/run/wpa_supplicant-<if>.conf` も同じ。**バージョン差ではなかった。**

ただし 24.10 で分かったこと:

- **AP モードは完全に動く**（`hostapd: phy0-ap0: AP-ENABLED`、br-lan に forwarding）
- → phy・ドライバ・hostapd の ubus 経路は正常。壊れているのは wpa_supplicant の経路だけ

## 第4の壁: DBDC を有効にすると設定が消える

DBDC を有効にすると `phy1` が生え、`wifi config` が `radio1` を作る。ここで2つ踏んだ:

1. **`radio1` は `disabled='1'` で生成される**（`wifi config` は最初の radio しか有効にしない）
   → `uci set wireless.radio1.disabled='0'` が必須
2. **`/etc/hotplug.d/ieee80211/10-wifi-detect` が無条件に `wifi config` を叩く**
   → phy1 が増えた瞬間に `/etc/config/wireless` が再生成され、`sta` も AP も消える
   → これが「再起動すると MyRouter が消える」の正体

さらに `radio1` を手書きしたとき `option type 'mac80211'` を忘れたため、
netifd がそのセクションをエラーも出さずに無視した（`phy1` はあるのに `phy1-ap0` が生えない）。

## 第5の壁: sched scan の永久リトライ

```
wpa_supplicant: phy1-sta0: Failed to initiate sched scan     ← 3秒ごと
```

`wpa_supplicant/scan.c:1717` のガードで sched scan が選ばれ、mt7615 では失敗し、
`scan.c:1954-1958` が通常スキャンにフォールバックしないため永久に無言。

`/lib/netifd/hostapd.sh:1323` の生成ヘッダ直後に `disable_scan_offload=1` を注入して解消。

## 最終的に効いた順序

```
START=10  boot（config_generate: 設定が既にあるのでスキップ）
START=18  dbdc → phy1 追加 → hotplug（設定があるのでスキップ）★パッチ
START=19  wpad
START=20  netifd（radio0=STA / radio1=AP を設定どおり起動）
```

## 実測できた完成形

```
dbdc: dbdc=1 phys=phy0 phy1
phy1-ap0   MyRouter   ch36 80MHz  AP
phy0-sta0  <上流>     ch1  managed
wwan up:true / DHCP / ping 0% loss
端末 → curl https://www.google.com → 200
```

## 検証に使った周辺

- `tools/run_tests.sh`: mock の `uci`/`wifi`/`ubus`/`logread` を使った 181 ケースの回帰テスト
  （`setup.sh` 用。PASS=181 / FAIL=0）
- `tools/in-container-run.sh` + `tools/Dockerfile`: イメージから rootfs を取り出し、
  Docker + `qemu-mipsel-static` で **本物の busybox ash と本物の uci** を動かして `setup.sh` を完走させる検証
  （binfmt_misc での chroot は EINVAL で不可、qemu-user はゲストの execve を扱えないので
  「外部コマンドを qemu ラッパーにする」方式にした）
