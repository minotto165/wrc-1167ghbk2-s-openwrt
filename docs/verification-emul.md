# エミュレーション検証レポート — setup.sh を「本物の ash + 本物の uci」で走らせる

担当: emul-runner / 共有タスク `task-3`
対象: `~/openwrt-setup/setup.sh`（**変更していない**。`emul/work/setup.sh` はコピー）
日時: 2026-11-18 14:00–15:05 JST
環境: macOS (Darwin 27.0.0 / arm64, Apple M1) + Docker Desktop 4.82.0 (Server 29.6.1, LinuxKit aarch64)

## 0. 結論（先に）

**本物の `uci`（mipsel ELF）と本物の `busybox ash`（rootfs の `/bin/sh`）で、`setup.sh` を最後まで走らせられた。**
モックではなく、焼く予定のイメージから取り出した rootfs の `/sbin/uci` / `/bin/sh` を qemu-mipsel で実行し、
`/etc/config/{network,wireless,firewall}` の実際の書き換え結果まで確認した（run1/run2/run3、3 回分のログあり）。

できないのは**カーネルとデーモン層**だけ: netifd / ubus / procd / wpa_supplicant / nftables / 無線ドライバ。
したがって「設定が書けるか・冪等か・uci の文法が通るか」は検証済み、「実際に学校 Wi-Fi に繋がるか」は未検証。

| 項目 | 結果 |
|---|---|
| 本物の `uci` で実行 | **できた**（`/sbin/uci`, mipsel, musl, uci 20250120） |
| 本物の `ash` で実行 | **できた**（busybox 1.37.0 の `/bin/sh`） |
| 実機イメージの rootfs 使用 | **できた**（squashfs を展開、26MB） |
| 2 回目実行の冪等性 | **設定ファイルがバイト一致**（run2 と run3 の config が identical） |
| `sta_wan` / `@zone[1]` の扱い | **本物の uci で期待通り**（下記 §5） |
| 無線の実接続・EAP | **未検証**（カーネル/ドライバ/wpa_supplicant が無い） |

## 1. 最初の環境調査

```
Darwin macbook-pro.local 27.0.0 arm64
brew 7.0.13 (/opt/homebrew)   … qemu / squashfs は未インストール
qemu-mipsel, qemu-mipsel-static, qemu-system-mipsel … どれも無し
unsquashfs, mksquashfs … 無し
busybox … 無し
docker … /usr/local/bin/docker あり（デーモンは停止中）
python3 3.9.6 … あり
```

- `brew install qemu` は**使っていない**。理由: macOS の Homebrew qemu は基本 `qemu-system-*` のみで
  `qemu-mipsel-static`（user-mode）を配らない構成が多く、また macOS ネイティブでは Linux の
  syscall ABI をそのまま扱えない。**Linux コンテナ内の qemu-user の方が確実**なのでそちらへ直行した。
- `open -a Docker` → **5 秒でデーモン起動**（ダイアログ操作は不要だった）。
  Docker Desktop CLI (`docker desktop stop/start`) も利用可。

## 2. イメージの解析（実測値）

`~/Downloads/wrc-1167ghbk2-s_v0.00.bin` = 8,388,677 B

| 範囲 | 内容 |
|---|---|
| `0x00`–`0x1F` (32B) | ELECOM ヘッダ `454c4543 4f4d2057 52432d31 31363747 48424b32 2d532076 302e3030 00000000` = `"ELECOM WRC-1167GHBK2-S v0.00"` |
| `0x20`–`0x5F` (64B) | uImage ヘッダ: `size=3326139`, `load=0x80001000`, `ep=0x80001000`, `os=5(Linux)`, `arch=5(MIPS)`, `type=2`, `comp=3`, name=`MIPS OpenWrt Linux-6.12.112` |
| `0x20`+64 … | カーネル本体（`0x20+64+3326139 = 3326235` で終端、**隙間 0**） |
| `3326235` (0x32C05B) … EOF-33 | **squashfs**（`hsqs`, little endian, v4.0, **xz**, blocksize 262144, 1210 inodes, 作成 2026-10-17） |
| 末尾 33B | md5 32 桁 + `\n` = `9e8523681e951c2cbbb051f26da86401\n` |

切り出しと展開（実際に使ったコマンド）:

```bash
# 1) squashfs 部分だけ切り出す（Python; 32B ヘッダ + uImage 64B + 3326139B カーネル）
python3 - <<'EOF'
d=open('~/Downloads/wrc-1167ghbk2-s_v0.00.bin','rb').read()
open('root.sqfs','wb').write(d[3326235:len(d)-33])
EOF

# 2) コンテナ内で展開
unsquashfs -d /w/rootfs -no-progress root.sqfs      # 26MB, 1210 inode
```

rootfs の中身（実物）: `/bin/busybox`(1.37.0, mipsel, musl), `/bin/sh`, `/sbin/uci`, `/sbin/wifi`,
`/sbin/fw4`, `/usr/bin/ucc`, `/usr/lib/libuci.so.20250120`, `/lib/ld-musl-mipsel-sf.so.1`(**soft-float**, MIPS32r2),
`/etc/config/firewall`（**lan/wan ゾーンの実物**）が入っている。
一方 `/etc/config/network` と `wireless` は**イメージに含まれない**（起動時に `config_generate` が作る）ので、
この 2 つだけは実機の形に合わせて**手書き**した（§4 の制約）。

## 3. 試行錯誤（同じ穴に落ちないための記録）

### 3-1. binfmt_misc での chroot 方式 → 失敗（と事故）

`docker run --privileged` + `mount -t binfmt_misc` は可能。しかし登録が通らない:

```
printf '%s' ":mipsel:M::\x7fELF...::\xff...:/usr/local/bin/qemu-mipsel-static:PCF" > register
→ write error: Invalid argument
```

分かったこと:
1. register に書くのは**生バイトではなく `\x7f` 形式の文字列**（生バイトだと EINVAL）。
2. register は **1 行 256 バイト未満**しか受けない（Debian の `/usr/share/binfmts/qemu-mipsel` の
   38B magic + 長い interpreter パスだと 345B になり EINVAL）。
3. この VM のカーネルは **`P`(preserve-argv0) フラグを拒否**する（`CF` は可）。
4. **【事故】mask を全部 `0xff` にしたワイルドカード ELF 登録を 1 回やってしまい、
   共有 VM の binfmt テーブル経由で Docker 自身の ELF 実行が壊れた**
   （`failed to start shim: fork/exec /usr/bin/containerd-shim-runc-v2: no such file or directory`）。
   `docker desktop stop && docker desktop start` で VM が再起動して復旧。
   → **`register-binfmt.sh` は残しているが、ワイルドカードは絶対に登録しないこと。**

### 3-2. binfmt なしの qemu-user で「ゲストが別の mipsel バイナリを exec」→ 失敗

`qemu-mipsel-static -L rootfs rootfs/sbin/uci show wireless` は**動く**（これが本命の確認）。
ところが **ゲストの ash から `grep`/`sed`/`sleep`/`uci` を呼ぶと**:

```
/w/setup.sh: line 74: grep: Exec format error
qemu: uncaught target signal 11 (Segmentation fault)   # uci を直接 exec した場合
```

`/bin/grep` は busybox へのシンボリックリンクで、qemu-user 7.2 はゲストの `execve()` を
ホストの exec に丸投げするため、mipsel ELF をホストカーネルが実行しようとして ENOEXEC / segv になる。
（chroot 方式が成立するのは binfmt_misc があるから、という当然の話。）

### 3-3. 採用した方式（最終形）

**ゲスト（本物の ash）はスクリプトの解釈だけを担当し、外部コマンドは全部「ホスト sh のラッパー →
qemu-mipsel」に置き換える。**

```
/w/bin/<cmd>  =  #!/bin/sh
                 exec /usr/bin/qemu-mipsel-static -L /w/rootfs /w/rootfs/{bin,usr/bin,sbin}/<cmd> "$@"
PATH(ゲスト) = /w/bin のみ
実行          = qemu-mipsel-static -L /w/rootfs /w/rootfs/bin/sh /w/setup.sh
/etc/config   = コンテナの /etc/config → /w/rootfs/etc/config への symlink
                （qemu-user はゲストの絶対パスを書き換えないので、ホスト側で合わせる）
```

これで `setup.sh` の `$(...)`, パイプ, `set -u`, `[ ]`, `printf`, `sed -n`, `grep -q`, `tr` は
**すべて本物の busybox 1.37 と本物の uci** が処理する。所要時間は 1 回 **3〜4 秒**。

## 4. 実行結果

`emul/in-container-run.sh <label> [ubus-stub]` を 3 回。ログは `emul/work/logs/`。

| run | 条件 | 終了コード | 出力 |
|---|---|---|---|
| run1 | 実機同様（ubus 無し） | 1 | `STA側=radio1 (5g) / AP側=radio0 (2g)` → `AP側 iface=default_radio0` → `wan ゾーン=@zone[1] に wwan を追加` → `WARN: wwan が up になりませんでした` → `exit 1` |
| run2 | run1 の直後にもう一度 | 1 | run1 と**同じ**。`sta_wan` 1 個、`network 'wwan'` 1 個（重複なし） |
| run3 | `ubus` をスタブ（`{"up": true, "ipv4-address":[{"address":"10.8.0.42"}]}`） | **0** | `OK: 学校Wi-Fiに接続しました (IP: 10.8.0.42)` |

run2 と run3 の `/etc/config/{network,wireless,firewall}` は **バイト一致**（`diff -q` で identical）＝
**本物の uci に対して冪等**。

### run1 の実行ログ（実物）

```
[setup] STA側=radio1 (5g) / AP側=radio0 (2g)
[setup] AP側 iface=default_radio0
[setup] wan ゾーン=@zone[1] に wwan を追加
[setup] WARN: wwan が up になりませんでした。次のログを確認してください:
[setup] --- wifi status ---
### setup.sh exit=1  elapsed=3s
```

### 生成された設定（差分の要点）

`/etc/config/wireless`（`uci commit` 後の実ファイル）:

```
config wifi-device 'radio0' … option country 'JP'      ← §3 のループで追加
config wifi-iface 'default_radio0'                     ← 既存 AP iface を再利用（ap_lan は作られない）
	option ssid 'MyRouter-emul'
	option encryption 'psk2'
	option key 'openwrt1234'
config wifi-iface 'sta_wan'
	option device 'radio1'
	option mode 'sta'
	option network 'wwan'
	option ssid 'TEST-CAMPUS-WPA2'
	option encryption 'wpa2'
	option eap_type 'peap'
	option identity 's2345678@example.ac.jp'
	option password 'p@ssw0rd-dummy'
	option ca_cert_usesystem '1'
	option ieee80211w '0'
	option auth 'MSCHAPV2'
```

`/etc/config/network` の末尾:

```
config interface 'wwan'
	option proto 'dhcp'
	option disabled '0'
```

`/etc/config/firewall` の wan ゾーン:

```
config zone
	option name 'wan'
	list network 'wan'
	list network 'wan6'
	list network 'wwan'     ← 追加された（2 回目以降も 1 個のまま）
	...
	option masq '1'
	option mtu_fix '1'
```
（`masq` は元から `1`。`@zone[1].masq='1'` が通ったことになる）

## 5. 本物の uci で分かったこと（モックとの差が出る所）

1. **`@zone[1]` への set / add_list は通る**。`WAN_ZONE=$(u show firewall | sed -n "s/^firewall\.\([^.]*\)\.name='wan'$/\1/p" | head -n1)`
   は実機でも `@zone[1]` を返し、`uci set firewall.@zone[1].masq='1'` と
   `uci add_list firewall.@zone[1].network='wwan'` は**匿名セクションのまま成功**した。
2. **`uci show` の出力は `key='value'`（シングルクォート）で、値にスペースを含むリストは
   `network='wan' 'wan6' 'wwan'` の形**。スクリプトの sed はこの形式に依存しているが、実機出力と一致。
3. **`uci commit` はファイルを丸ごと再生成する**。コメント行（`/etc/config/firewall` の
   `# We need to accept udp ...` など）は全部消え、各ファイルの先頭に空行が 1 行入る。
   つまり「setup.sh 実行後に設定ファイルのコメントが消える」のは仕様（バグではない）。
   冪等性の判定にファイル全体の diff を使うと、この正規化で毎回差分が出るので注意。
4. **`uci -q get <section>` は未定義なら終了コード 1**。スクリプトの
   `if ! u get network.wwan >/dev/null 2>&1; then u set network.wwan=interface; fi` は期待通り。
5. **`u delete wireless.sta_wan` は存在しなくても `-q` で無害**（2 回目実行が通ることで確認）。
6. `ap_iface_on` は実機の `default_radio0`（mode=ap, device=radio0）を正しく拾い、
   **新しい `ap_lan` を作らない**。ただし §7-3 の注意あり。

## 6. この方法で**検証できない**こと

| 層 | 状態 | 影響 |
|---|---|---|
| カーネル / 無線ドライバ (mt76) | 無い | 電波は出ない。`country`/`channel` の妥当性は未検証 |
| netifd | 無い（`ubus` 不在） | `wwan` が up にならず、スクリプトは必ず `exit 1` 側に落ちる（run3 はスタブで回避） |
| wpa_supplicant / EAP | 無い | **本題の WPA2-Enterprise 認証は一切検証できていない** |
| `wifi` コマンド | 実行しても `/lib/functions.sh` 等がホストに無く失敗（stderr は 2>/dev/null で隠れる） | `wifi config`（無線設定の自動生成）は未検証 |
| nftables / fw4 | 無い | `/etc/init.d/firewall restart` はスタブ（`fw-stub`）に差し替え。実機での可否は未検証 |
| `/etc/config/network`, `wireless` | **手書き**（イメージに無い） | 「実機の初期状態」とは厳密には違う。特に端末名 `lan1..4`/`wan` は推定 |

## 7. 実機で最初に確認すべき点（この検証から見えた順）

1. **`uci show wireless` の `band` が本当に `'5g'`/`'2g'` か**（`wifi config` 生成直後）。
   ここが `'5g'` でないと `DEV_STA` が空で即 die する。実機で `uci show wireless | grep band` を最初に見る。
2. **`network.wwan` に `option device` が無い**。`proto dhcp` だけの interface は、netifd が
   `wifi-iface ... network 'wwan'` の netdev を拾える環境なら動くが、拾えないと `wan` 側が
   `wwan` デバイスを探して up しない。実機で `ifstatus wwan` を見る（ここは emul では絶対に分からない）。
3. **AP iface の再利用**: `ap_iface_on radio0` が実機で `default_radio0` を返す前提。
   ただし OpenWrt 25.12 の生成物は `default_radio0` の `network` が `lan` であることが前提で、
   もし `wan` や他ネットワークだと AP 側が LAN に乗らない。
4. **`wifi reload` 後に `uci show wireless` の `band` が消えないか**（`wifi reload` は設定を作り直さないが、
   初回は `wifi config` が走るケースがある）。run1 では `wifi config` を呼ばずに済んだが、実機初回は呼ばれる。
5. **`firewall` の `wan` ゾーンが `@zone[1]` で固定されないこと**（将来 `/etc/config/firewall` の並びが変わると
   `name='wan'` の sed で見つかる限りは安全。`@zone[1]` はフォールバックなので、見つかった場合は実名が入る）。

## 8. 再現手順

```bash
# 一度だけ: 作業イメージ（debian + qemu-user-static + squashfs-tools + busybox/dash）
docker build -t openwrt-emul:1 ~/openwrt-setup/emul

# イメージから squashfs を切り出し（emul/work/root.sqfs を作る）
docker run --rm -v ~/openwrt-setup/emul/work:/w -w /w openwrt-emul:1 \
  unsquashfs -d /w/rootfs -no-progress root.sqfs

# setup.sh を本物の ash + uci で実行（run1: 実機同様 / run3: ubus スタブで成功経路）
docker run --rm -v ~/openwrt-setup/emul:/e \
  -v ~/openwrt-setup/emul/work:/w -w /w openwrt-emul:1 \
  bash /e/in-container-run.sh run1
docker run --rm ... openwrt-emul:1 bash /e/in-container-run.sh run3 ubus-stub
```

## 9. 成果物

| パス | 内容 |
|---|---|
| `emul/emul-report.md` | 本レポート |
| `emul/Dockerfile` | 作業イメージ（qemu-user-static, squashfs-tools, busybox-static, dash, xxd） |
| `emul/in-container-run.sh` | 本命の実行ハーネス（ラッパー生成 → 本物の ash で setup.sh → 前後 diff） |
| `emul/register-binfmt.sh` | binfmt 登録の試行錯誤版（**ワイルドカード禁止**の注意書き付き。採用はしていない） |
| `emul/work/root.sqfs` | 切り出した squashfs（5,062,409 B） |
| `emul/work/rootfs/` | 展開した実 rootfs（26MB） |
| `emul/work/setup.sh` | 実行用コピー（原本は未変更） |
| `emul/work/logs/run{1,2,3}*.txt`, `run{1,2,3}.log` | 実行ログ・`uci show` の前後・commit 後の config コピー |
| `emul/work/pristine/` | 実行前の `/etc/config`（network/wireless は手書き、firewall はイメージ実物） |

---

# 追記（Lead による再実行） 2026-11-18 15:45 JST

本レポートの run1/run3 は **189行版 setup.sh**（`work/setup.sh` 7113B）に対するものだった。
Lead の修正後 `setup.sh`（280行, sha256 `50488fbd…f4c3`）を `emul/work/setup.sh` に差し替え、
同手順で再実行した。

| run | 条件 | 結果 |
|---|---|---|
| `p1` | 実機同様（ubus 無し） | `exit 1` / sta_wan 正常生成 / `WARN: ifup が見つかりません` が出る（新仕様） / firewall `@zone[1].network='wan' 'wan6' 'wwan'` |
| `p3` | ubus スタブ | **`exit 0`** / 同じ設定 / 4秒で完走 |
| `tls` | `EAP_TYPE=tls` + `EAP_AUTH=`（空） | **`exit 0`** / `wireless.sta_wan.auth` が**書かれない**ことを本物の uci で確認（修正1の検証） |
| `zone1` | firewall が lan ゾーン1個だけ | **`exit 1`** / lan ゾーンは汚れず（`network='lan'` のまま）、wwan 追加なし（修正2の検証） |

→ レポート §8 の再現手順（`docker run … in-container-run.sh <label> [ubus-stub]`）はそのまま使える。
`tls` 用の変種は `emul/icr-tls.sh`。`zone1` は `emul/work/pristine/firewall` を lan のみに差し替えて実行（実行後に復元済み）。
