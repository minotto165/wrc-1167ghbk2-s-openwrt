# setup.sh / 99-asu-defaults.sh 実行検証レポート

- 検証担当: harness-tester（task-2）
- 検証日時: 2026-11-18
- 実行環境: macOS 27.0.0 (arm64, macbook-pro.local) / BSD sed / python3 3.9.6
- **本レポートの結果は下記 2 ファイルの内容に紐づく**（検証中に setup.sh が他担当によって更新されたため、sha256 を明記する）

| 対象 | 行数 | sha256 | mtime |
|---|---|---|---|
| `setup.sh` | 280 | `ec9ac7d964f70914f8c1e39d3ff0f81b135cb2914b397a490339dc978999fcea` | Nov 18 15:02 |
| `99-asu-defaults.sh` | 25 | `fcf037b608b3b61c2a8791bcd7bb822294bfa46ece314ba75dda5af2b2766ea8` | Nov 18 13:54 |

> 注: 検証開始時の setup.sh は 189 行 / 7113B だったが、作業中（15:02）に別担当が 280 行版へ更新した。
> 本レポートと `tests/run_tests.sh` は **280 行版（上表の sha256）** に追随済み。以後 setup.sh が変わった場合は
> `tests/run_tests.sh` 冒頭に表示される sha256 が変わるので、結果の読み替えが必要。

---

## 1. 実行方法

```sh
# 既定（/bin/sh = macOS の bash 3.2）
sh tests/run_tests.sh

# ash の代用（dash）で全ケース実行
SH_BIN=/bin/dash sh tests/run_tests.sh

# 失敗ケースの stdout/stderr/状態を残す
KEEP=1 sh tests/run_tests.sh

# 実行内容を全部出す
VERBOSE=1 sh tests/run_tests.sh
```

終了コード: 全 PASS なら 0、FAIL があれば 1（BUG 注記だけでは 1 にならない）。
所要時間は約 2.5 分（mock が shell スクリプトなので 1 ケースあたり 20〜40 プロセス起動するため）。

## 2. 結果サマリ

**PASS=176 / FAIL=3 / BUG(注記)=4（32 ケース・183 アサーション）**

- `/bin/dash` と `/bin/sh`(bash 3.2) で **アサーション結果が完全一致**（`diff` で確認済み）。
  つまり setup.sh・99-asu-defaults.sh は bash 依存の書き方をしていない（POSIX の範囲で動く）。
- FAIL 3 件はすべて「実バグ由来」で、期待値側を緩めれば通る類のものではない。→ §4 で修正案。
- BUG 4 件は「テストは通るが実運用で困る挙動」。修正推奨。

## 3. ケース一覧と結果

「PASS/全」はアサーション通過数。**FAIL** はアサーション失敗（＝仕様と違う）、**BUG** は注記（＝動くが危険/不親切）。

| ケース | 内容 | PASS/全 | 判定 |
|---|---|---|---|
| `a_normal` | 正常系: radio0=2g / radio1=5g、STA=5g AP=2g | 39/39 | PASS |
| `a2_scratch` | 正常系(2): `/etc/config/wireless` が無い状態から生成させる | 8/8 | PASS |
| `a3_apiface_robust` | `ap_iface_on()`: device/mode が欠けた iface があっても壊れない | 6/6 | PASS |
| `b_idempotent` | 冪等性: 2 回実行しても設定が増えない | 7/7 | PASS |
| `b2_stale_sta_wan` | 冪等性(2): 古い sta_wan（別 device・残骸 option）を上書きする | 4/4 | PASS |
| `b3_foreign_sta` | 冪等性(3): 名前が違う既存 STA iface の扱い | 3/3 | PASS |
| `c_special_chars` | 特殊文字: パスワード/SSID に 空白 `& $ "` と **シングルクォート** | 10/10 | PASS |
| `c2_eap_conditional` | 条件付き option: EAP_AUTH 空 / EAP_ANON 有り / EAP_TYPE=ttls | 3/4 | **FAIL** |
| `d_no_5g` | 異常系: 5g ラジオが無い → 明確なエラーで exit 1 | 6/6 | PASS |
| `d2_no_2g` | 異常系(2): 2g ラジオが無い → AP 側で die | 3/3 | PASS |
| `e_zone_fallback` | ゾーン: `name='wan'` が無い → network から wan ゾーンを特定して wwan 追加 | 8/8 | PASS |
| `e2_single_zone` | ゾーン: ゾーンが 1 個だけ（末尾フォールバックが lan を選ぶ） | 2/4 | **FAIL** |
| `f_wwan_never_up` | 異常系: wwan が up にならない → exit 1 + ログ案内 | 7/7 | PASS |
| `f2_up_but_no_address` | 異常系(2): up だが address が取れない → IP は「取得中」 | 2/2 | PASS |
| `g_fw_restart_fail` | firewall restart が失敗 → warn のみで継続 | 3/3 | PASS |
| `h_fw_missing` | firewall init が無い環境 → 何もせず継続 | 2/2 | PASS |
| `i_delayed_up` | wwan が遅れて up する → 待って成功する | 4/4 | PASS |
| `k_same_radio` | バンド: STA と AP が同じラジオ → warn して続行 | 4/4 | PASS |
| `k2_band_auto` | バンド: AP_BAND=5g で AP_CHANNEL 未指定 → `auto` | 3/3 | PASS |
| `k3_band_chan_guard` | バンド: AP_BAND=5g + AP_CHANNEL=6（2g 用）→ `auto` に矯正 | 3/3 | PASS |
| `m_wifi_config_fail` | 異常系: wifi config が失敗して無線設定が生成されない | 4/4 | PASS |
| `n_network_apply` | 反映: commit 後に `ifup wwan` で netifd を起こす（回帰テスト） | 3/3 | PASS |
| `n2_ifup_missing` | 反映: `ifup` コマンド自体が無い環境 | 1/1 | PASS |
| `o_ca_cert` | CA_CERT 指定時は `ca_cert` を使い `ca_cert_usesystem=0` | 4/4 | PASS |
| `o2_wpad_ng` | 前提: EAP 非対応の `wpad-basic` → die | 3/3 | PASS |
| `o3_wpad_ok` | 前提: `wpad-mbedtls` → 続行 | 2/2 | PASS |
| `j99_fresh` | 初回起動: 設定が空の状態から AP を有効化 | 10/10 | PASS |
| `j99_twice` | 初回起動: 2 回実行しても壊れない | 3/3 | PASS |
| `j99_no_2g` | 初回起動: 2g ラジオが無い端末 | 3/3 | **BUG** |
| `j99_existing` | 初回起動: 既に AP 設定がある（`wifi config` を呼ばない） | 4/4 | PASS |
| `j99_sta_on_2g` | 初回起動: 2g 側に STA iface がある場合の巻き添え | 1/1 | **BUG** |
| `z_syntax` | 構文チェック: `sh -n` で全スクリプトをパース | 11/11 | PASS |

### 特に重視した 2 点の結果

**(1) パスワードに `'` や `$` が入ったとき → PASS**
`EAP_PASSWORD="p'a\"\$d e&f\\g#h\`i"`、`SCHOOL_SSID="Campus & 'Guest' \$Wi-Fi"` で実行し、
`uci show wireless` の出力を**シェルで再パース（eval）しても元の値に戻る**ことまで確認した。
mock uci は実機 libuci と同じく `'` を `'\''` にエスケープして `'...'` で囲むため、
「show の出力をコピペして手で直す」運用でも壊れない値になっている。
setup.sh 側も `u set wireless.sta_wan.password="$EAP_PASSWORD"` と必ず変数をクォートして渡しており、
`eval` や `$*` の連結をしていないので、この経路に脆弱性は無い。

**(2) ２回実行しても壊れないか（冪等性）→ PASS**
`b_idempotent`（同一条件で 2 回実行し、`uci show` の全出力を 1 回目と比較）で確認した内容:
- **2 回目の `uci show` が 1 回目と完全一致**（option の増減・順序の変化なし）
- firewall の wan ゾーンの network に **`wwan` が 1 つだけ**（二重に入らない）
- `mode='sta'` の iface は 1 つだけ、AP iface も増えない（`default_radio0/1` + `sta_wan` の 3 本）
- wireless のセクション総数が 5 のまま
- 2 回目も exit 0

`b2_stale_sta_wan`（古い sta_wan が別 device を指し、`auth` など残骸 option を持つ）でも、
`delete` → 再作成で正規の値に戻ることを確認。
`b3_foreign_sta`（`old_sta` という別名の STA iface が 5g ラジオに居る）では、
280 行版で追加された掃除処理（`setup.sh:151-157`）が効いて **1 本に収まり、`old_sta` は消える**。

## 4. FAIL の原因と修正提案

### FAIL-1 / BUG-1: EAP_AUTH を空にできない（EAP-TLS 構成が作れない）

- ケース: `c2_eap_conditional`
- 失敗: `EAP_AUTH=''` を渡しても `wireless.sta_wan.auth='MSCHAPV2'` が書かれる
- 原因: `setup.sh:28`

```sh
EAP_AUTH="${EAP_AUTH:-MSCHAPV2}"    # PEAP・TTLS-> MSCHAPV2 or PAP / TLS-> 空
```

`:-` は「未設定**または空文字**」で既定値に置き換わる。コメント自身が「TLS-> 空」と言っているのに、
空を渡す手段が無い（`EAP_AUTH=` としても MSCHAPV2 になる）。TLS では `auth` を書いてはいけないので実害あり。

**修正案（1 行）**

```diff
-EAP_AUTH="${EAP_AUTH:-MSCHAPV2}"
+EAP_AUTH="${EAP_AUTH-MSCHAPV2}"     # 未設定なら MSCHAPV2、空にすれば auth を書かない
```

`setup.sh:171` の `if [ -n "$EAP_AUTH" ]; then ...` はそのままで意図どおり動く。

### FAIL-2/3 / BUG-2: ゾーンが 1 個だけだと lan ゾーンに wwan を混ぜる

- ケース: `e2_single_zone`（firewall に `lan` ゾーンだけがある構成）
- 失敗:
  - `lan ゾーンに wwan を混ぜない` → 実際は `firewall.z1.network='lan' 'wwan'`
  - `lan ゾーンに masq を立てない` → 実際は `firewall.z1.masq='1'`
- 原因: `setup.sh:212-231` の `find_wan_zone()` の第 3 フォールバック

```sh
	# 3) 最後のゾーン（fw4 の既定 wan は末尾）
	for x in $(zone_list); do z="$x"; done
	[ -n "${z:-}" ] && warn "wan ゾーンを名前で特定できず、末尾のゾーン($z)を使います"
```

ゾーンが 1 個（=lan）のときは「末尾」が lan になる。そのまま `masq=1` と `network += wwan` を実行するので、
**wwan（学外/学内ネットワーク）のトラフィックが lan ゾーン扱いになり、LAN 側へ転送されうる**。
masq も lan に立つ。警告は出るが exit 0 で「成功」扱いになるため、実運用では気づきにくい。

**修正案: フォールバック候補から lan 系を除外し、候補が無ければ die する**

```diff
 	# 3) 最後のゾーン（fw4 の既定 wan は末尾）— ただし lan 系は除外
 	for x in $(zone_list); do z="$x"; done
-	[ -n "${z:-}" ] && warn "wan ゾーンを名前で特定できず、末尾のゾーン($z)を使います"
+	case "$(u get firewall.${z:-none}.name 2>/dev/null)" in
+		lan|lan6|'')
+			# lan を wan 代わりに使うと wwan から LAN へ入れる構成になるので中止
+			warn "wan ゾーンが見つかりません（lan ゾーンは使えません）"
+			z='' ;;
+		*)	warn "wan ゾーンを名前で特定できず、末尾のゾーン($z)を使います" ;;
+	esac
 	echo "${z:-}"
```

これで `WAN_ZONE` が空 → `setup.sh:231` の `die "wan ゾーンが見つかりません…"` に落ち、
「設定は書いたが通信できない」ではなく「設定前に止まる」挙動になる。
（`e_zone_fallback` の経路＝ network に `wan` を含むゾーンがある場合は従来どおり動く。8/8 PASS のまま）

> 別案: `network` に `wan` を含むゾーンが無い場合に、`wan` という名前で**新規ゾーンを作る**。
> ただし fw4 の既定構成から外れるので、明示エラーの方が安全。

## 5. BUG（動くが直したい）— 初回起動スクリプト

### BUG-3: 2g ラジオが無い端末で無言 no-op

- ケース: `j99_no_2g`（`MOCK_RADIOS="radio1:5g"`）
- 症状: `dev=$(... band='2g' ...)` が空 → `if [ -n "$dev" ]` が偽 → 何もせず `exit 0`、stderr も空
- 影響: LuCI に有線で入らないと復旧できない状態なのに、スクリプトは成功したように見える
- 修正案（`99-asu-defaults.sh:13-23` に else を足す）

```diff
 if [ -n "$dev" ]; then
 	...
 	uci -q commit wireless
+else
+	echo "99-asu-defaults: 2g ラジオが見つかりません。Wi-Fi は有効化できませんでした" >&2
 fi
```

### BUG-4: `device='radio0'` の sed が AP 以外の iface も拾う

- ケース: `j99_sta_on_2g`（radio0 に `mode='sta'` の iface がある）
- 症状: `99-asu-defaults.sh:16` の

```sh
	for ifc in $(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)\.device='$dev'/\1/p"); do
```

は device しか見ないため、同じラジオ上の **STA iface まで `ssid`/`key`/`encryption=psk2` に上書き**する。
AP にしたい iface だけを対象にすべき。

- 修正案（mode=ap で絞る）

```diff
 	for ifc in $(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)\.device='$dev'/\1/p"); do
+		[ "$(uci -q get wireless.$ifc.mode)" = "ap" ] || continue
 		uci -q set wireless.$ifc.disabled='0'
```

初回起動時は既定 iface が `mode='ap'` なので挙動は変わらず、STA が同居する構成だけが安全側に倒れる。

### BUG-5（note）: `ifup` が無い環境では警告なしに待ちループへ入る

- ケース: `n2_ifup_missing`（`IFUP=/nonexistent`）
- 280 行版で `setup.sh:247` に `ifup wwan` が入り、`n_network_apply` は PASS になった（良い修正）。
  ただし `command -v "$IFUP"` が偽のときは**何も言わずに**待ちループへ進み、
  60 秒後に「EAP ログを見ろ」と案内するため原因を誤認する。
- 修正案:

```diff
-command -v "$IFUP" >/dev/null 2>&1 && { $IFUP wwan >/dev/null 2>&1 || true; }
+if command -v "$IFUP" >/dev/null 2>&1; then
+	$IFUP wwan >/dev/null 2>&1 || warn "ifup wwan が失敗しました"
+else
+	warn "$IFUP が見つかりません（wwan が起動しない可能性）"
+fi
```

## 6. その他の静的レビュー所見（テスト未カバー／提案）

1. **既定値のまま実行できてしまう**（`setup.sh:24-26`）: `SCHOOL_SSID=CHANGE-ME-CAMPUS-SSID` /
   `EAP_IDENTITY=CHANGE-ME@example.ac.jp` / `EAP_PASSWORD=CHANGE-ME`。
   プレースホルダがそのままなら `die` する 1 行があると事故が減る:
   `case "$SCHOOL_SSID$EAP_IDENTITY$EAP_PASSWORD" in *CHANGE-ME*) die "設定値（SCHOOL_SSID/EAP_*）を書き換えてください" ;; esac`
2. **`local z`（`setup.sh:214`）**: POSIX 外だが busybox ash / dash / bash は対応。zsh でも動く。
   `ksh` 系も `typeset` 互換で動くため実害は無いが、厳密 POSIX を謳うなら `typeset` を避けて関数内変数をリネームする。
3. **`/etc/ssl/certs/ca-certificates.crt` のハードコード**（`setup.sh:88`）: 存在しなければ warn のみ。
   ca-bundle のパスは OpenWrt で固定なので問題なし（テストでは常に warn が出る）。
4. **`$WIFI reload` の失敗を検査していない**（`setup.sh:246`）: 失敗しても先へ進む。warn を 1 行足すと親切。
5. **`u commit firewall` 等の戻り値未検査**（`setup.sh:242-244`）: 同上。実機では稀。
6. **`find_wan_zone` の第 2 段**（`setup.sh:217-223`）: `network` に `wan` を含むゾーンを探す実装は妥当。
   fw4 既定でも `wan` ゾーンの network は `wan wan6` なので、名前変更構成にも追従できる。
7. **`AP_BAND` と `STA_BAND` が同じ場合**（`k_same_radio`）: warn のみで続行。1 ラジオ機では避けられないので妥当。
8. **`sed` は BSD/GNU 両対応**: 使用している式はすべて BRE + `\1` + `[^.]` で、BSD sed（本検証）で動作。
   GNU sed でも同じ結果になる（`-n` の範囲指定や GNU 拡張は未使用）。

## 7. モックの精度と限界（結果の読み方）

`tests/mocks/` はすべて POSIX sh で書いた **uci / wifi / ubus / logread / sleep / ifup / firewall-init** の代替。
状態はファイル木（`$UCI_STATE/p/<pkg>/...`）に持つ。

**実機に寄せた点**
- `uci show` の出力形式（`pkg.sec=type` / `pkg.sec.opt='val'`、匿名は `pkg.@type[idx]=type`）
- 文字列の `'` エスケープ（`'\''`）と、その出力を shell で再パースできること（`c_special_chars` で検証）
- `@zone[1]` の解決を「**匿名/名前付きを問わず全ゾーンの N 番目**」で行う（実機 libuci の挙動）
- `uci -q get <存在しないセクション>` は「空文字を出して終了コード 1」（`ap_iface_on` の `set -u` 耐性検証の要）
- `uci add_list` の重複追加・`delete` の冪等性
- `wifi config` が既存設定を壊さない（order が既にあれば no-op）
- `ubus call network.interface.wwan status` が **ifup されるまで up にならない**モード
  （`MOCK_WWAN_REQUIRES_IFUP=1`。これで「commit したのに netifd が起動していない」実機症状を再現）

**限界（ここは実機でしか分からない）**
- **busybox ash での実行は未実施**。本機に busybox が無く、Docker デーモンは起動しているものの
  `docker run` が `fork/exec /usr/bin/containerd-shim-runc-v2: no such file or directory` で失敗するため
  コンテナも使えない（イメージは `openwrt-emul:1`, `debian:bookworm-slim` のみ）。
  代わりに **`/bin/dash`（ash の直系の親戚）と bash 3.2 の両方で全ケース実行し、アサーション結果が完全一致**
  することを確認した。`local` / `$(( ))` / `case` / `[ ]` など使用機能はすべて ash 互換。
- `uci commit` は実ファイルを書かない（no-op）。よって「commit 後に再起動しても残るか」は未検証。
- `wifi reload` / `wifi up` の実際の hostapd/wpa_supplicant 起動は未検証（呼ばれた事実だけ記録）。
- `logread` は固定 8 行。実際の EAP 失敗ログの多様性は無い。
- `sleep` は即時 return（待ち時間の実測はできない）。
- `/etc/config/wireless` は macOS に存在しないため、`setup.sh:92` の「無いので生成する」分岐は**常に真**。
  「既にある」分岐は `a_normal` 系（`prep_wireless_dual` で先に状態を作る）でカバーしているが、
  実ファイルの存在判定そのものは差し替えできない（注入点が無い）。

## 8. 再現手順（FAIL を手で確認する）

```sh
cd ~/openwrt-setup

# FAIL-1: EAP_AUTH='' が MSCHAPV2 に化ける
SH_BIN=/bin/dash KEEP=1 sh tests/run_tests.sh 2>&1 | sed -n '/c2_eap_conditional/,/^$/p'

# FAIL-2/3: ゾーン 1 個で lan に wwan が入る
SH_BIN=/bin/dash KEEP=1 sh tests/run_tests.sh 2>&1 | sed -n '/e2_single_zone/,/^$/p'
# KEEP=1 のとき表示される作業ディレクトリで:
#   UCI_STATE=<work>/cases/e2_single_zone <work>/bin/uci show firewall
```

## 9. まとめ

- 32 ケース・183 アサーションを bash 3.2 と dash で実行し、**結果は両者で完全一致**。
- 実バグとして確定したのは **2 件**（EAP_AUTH を空にできない / 単一ゾーン時に lan ゾーンへ wwan を混ぜる）。
  どちらも修正は数行。
- 初回起動スクリプトは **2 件の改善推奨**（2g 無しの無言 no-op / STA iface への巻き添え上書き）。
- 冪等性・特殊文字・異常系（ラジオ欠落・生成失敗・wwan 不起動・firewall 再起動失敗）はいずれも PASS。
  特に「2 回実行してもセクションも wan ゾーンの network も増えない」ことは実行して確認済み。

---

# 追記（Lead による修正後・最終） 2026-11-18 15:47 JST

## 修正を適用した成果物

| ファイル | 修正前 sha256 | 修正後 sha256 |
|---|---|---|
| `setup.sh` | `ec9ac7d9…fcea`（280行） | `50488fbd…f4c3` |
| `99-asu-defaults.sh` | `fcf037b6…6ea8` | `5900325f…b2b5` |
| `tests/run_tests.sh` | — | 期待値を新仕様に更新 |

## 適用した修正（本レポート §4 の指摘に対応）

1. `setup.sh:28` `EAP_AUTH="${EAP_AUTH:-MSCHAPV2}"` → `EAP_AUTH="${EAP_AUTH-MSCHAPV2}"`（`EAP_AUTH=` で空にできる）
2. `find_wan_zone()` 第3フォールバック: name が `lan`/`lan6` のゾーンを候補から除外。残らなければ `die`（lan 混入を根絶）
3. `ifup` 不在時: 無言スキップ → `warn` 1行（誤認防止）
4. `99-asu-defaults.sh`: iface ループ先頭に `[ mode = ap ] || continue`（2g側 STA の巻き添え防止）
5. 同: 2g ラジオが無い場合に stderr 1行警告

## 再実行結果

```
SH_BIN=/bin/dash sh tests/run_tests.sh
結果: PASS=181  FAIL=0  BUG(注記)=0   (exit 0)
```

`e2_single_zone` は「die する」期待に、`j99_no_2g` は「警告を出す」期待に、`j99_sta_on_2g` は「STA iface に触らない」期待に更新済み。
なお `j99_*` の修正は**焼き済みイメージには反映されない**（将来の再ビルド用）。
