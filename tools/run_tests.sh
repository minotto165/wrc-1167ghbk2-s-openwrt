#!/bin/sh
# ==========================================================================
# run_tests.sh — openwrt-setup のロジック検証ハーネス（ネットワーク不要）
#
#   sh tests/run_tests.sh                    # 既定: /bin/sh（macOS は bash 3.2）
#   SH_BIN=/bin/dash sh tests/run_tests.sh   # ash の代用（dash）で全ケース実行
#   SH_BIN=/bin/dash SH_ARGS= sh tests/run_tests.sh
#   VERBOSE=1 sh tests/run_tests.sh          # PASS したケースのログも表示
#   KEEP=1    sh tests/run_tests.sh          # 作業ディレクトリを残す
#
# 対象（どちらも一切書き換えない・読み取り専用）:
#   setup.sh               … mock した uci/wifi/ubus/logread/sleep/firewall で実行
#   99-asu-defaults.sh     … 注入点が無いので PATH シム（mocks/ を先頭に置く）で実行
#
# 終了コード: FAIL が 0 件なら 0、1 件以上なら 1
# ==========================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd) || exit 2
MOCKS="$HERE/mocks"
SETUP_SH="$ROOT/setup.sh"
FIRSTBOOT_SH="$ROOT/99-asu-defaults.sh"
SH_BIN=${SH_BIN:-/bin/sh}
SH_ARGS=${SH_ARGS:-}
VERBOSE=${VERBOSE:-0}
KEEP=${KEEP:-0}

[ -f "$SETUP_SH" ] || { printf 'setup.sh が見つかりません: %s\n' "$SETUP_SH" >&2; exit 2; }
[ -f "$FIRSTBOOT_SH" ] || { printf '99-asu-defaults.sh が見つかりません: %s\n' "$FIRSTBOOT_SH" >&2; exit 2; }

PASS=0
FAIL=0
BUG=0
BUGNOTES=""
FAILNOTES=""

WORK=$(mktemp -d "${TMPDIR:-/tmp}/owrt-harness.XXXXXX") || exit 2
BINDIR="$WORK/bin"
STATE_ROOT="$WORK/cases"
mkdir -p "$BINDIR" "$STATE_ROOT"

cleanup() {
	if [ "$KEEP" = "1" ] || [ "$FAIL" -gt 0 ]; then
		printf '\n[harness] 作業ディレクトリを残しました: %s\n' "$WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup 0 1 2 3 15

# ---- ラッパ生成（mock も SH_BIN で動かす＝ash 互換の検証） ----------------
make_wrappers() {
	for m in uci wifi ubus logread sleep firewall-init firewall-init-fail ifup; do
		cat >"$BINDIR/$m" <<EOF
#!/bin/sh
exec "$SH_BIN" $SH_ARGS "$MOCKS/$m" "\$@"
EOF
		chmod +x "$BINDIR/$m"
	done
}

# ---- アサーション --------------------------------------------------------
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; FAILNOTES="$FAILNOTES
  * [$CASE] $*"; }
bug()  { BUG=$((BUG + 1));  printf '  BUG   %s\n' "$*"; BUGNOTES="$BUGNOTES
  * [$CASE] $*"; }
note() { printf '  note  %s\n' "$*"; }

assert_eq() { # desc want got
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		bad "$1"
		printf '          want: %s\n          got : %s\n' "$2" "$3"
	fi
}

assert_contains() { # desc needle haystack
	case "$3" in
		*"$2"*) ok "$1" ;;
		*) bad "$1"; printf '          含まれない: %s\n          実際: %s\n' "$2" "$(printf '%s' "$3" | head -n 3)" ;;
	esac
}

assert_lacks() { # desc needle haystack
	case "$3" in
		*"$2"*) bad "$1"; printf '          含まれてはいけない: %s\n' "$2" ;;
		*) ok "$1" ;;
	esac
}

assert_present() { # desc key
	if has_key "$2"; then
		ok "$1"
	else
		bad "${1}（未設定: ${2}）"
	fi
}

assert_absent() { # desc key
	if has_key "$2"; then
		bad "${1}（設定されている: $2 = $(field "$2")）"
	else
		ok "$1"
	fi
}

assert_rc() { # desc want
	if [ "$RC" = "$2" ]; then
		ok "$1"
	else
		bad "${1}（want rc=$2, got rc=${RC}）"
		printf '          stderr: %s\n' "$(tail -n 3 "$ERRLOG" 2>/dev/null | tr '\n' ' ')"
	fi
}

assert_count() { # desc want pattern pkg
	assert_eq "$1" "$2" "$(show_n "$4" "$3")"
}

# ---- 状態アクセサ --------------------------------------------------------
field()   { "$BINDIR/uci" -q get "$1" 2>/dev/null || true; }
has_key() { "$BINDIR/uci" -q get "$1" >/dev/null 2>&1; }
show_n()  { "$BINDIR/uci" -q show "$1" 2>/dev/null | grep -c -- "$2" 2>/dev/null || true; }
uciq()    { "$BINDIR/uci" "$@"; }
sleeps()  {
	if [ -f "$CASE_STATE/.sleep_calls" ]; then
		wc -l <"$CASE_STATE/.sleep_calls" | tr -d ' '
	else
		printf '0'
	fi
}
ubus_n() { cat "$CASE_STATE/.ubus_wwan_calls" 2>/dev/null || printf '0'; }
calls()  { cat "$CASE_STATE/calls.log" 2>/dev/null || printf ''; }
fwl()    { cat "$CASE_STATE/fw.log" 2>/dev/null || printf ''; }
out_txt() { cat "$OUT" 2>/dev/null || printf ''; }
err_txt() { cat "$ERRLOG" 2>/dev/null || printf ''; }

# ---- 状態の初期化 -------------------------------------------------------
reset_env() {
	export UCI="$BINDIR/uci"
	export WIFI="$BINDIR/wifi"
	export FW_INIT="$BINDIR/firewall-init"
	export IFUP="$BINDIR/ifup"
	export UBUS="$BINDIR/ubus"
	export LOGREAD="$BINDIR/logread"
	export SLEEP="$BINDIR/sleep"
	export WAIT_WIFI=5
	export WAIT_WAN=6
	# mock 側のつまみ
	export MOCK_UCI="$BINDIR/uci"
	export MOCK_RADIOS="radio0:2g radio1:5g"
	export MOCK_WIFI_CONFIG_FAIL=0
	export MOCK_WWAN_UP=1
	export MOCK_WWAN_UP_AFTER=0
	export MOCK_WWAN_ADDR=192.0.2.10
	export MOCK_WWAN_REQUIRES_IFUP=0
	# setup.sh の設定値
	export SCHOOL_SSID='School-WiFi'
	export EAP_IDENTITY='student@example.ac.jp'
	export EAP_PASSWORD='secret123'
	export EAP_TYPE='peap'
	export EAP_AUTH='MSCHAPV2'
	export EAP_ANON=''
	export CA_USESYSTEM=1
	export CA_CERT=''
	export PMF=0
	export STA_BAND=5g
	export AP_BAND=2g
	export AP_SSID='MyRouter'
	export AP_KEY='openwrt1234'
	export AP_CHANNEL=''
	export AP_RADIOS_EXTRA=''
	EXTRA_PATH=''
}

begin() { # case-name 説明
	CASE=$1
	CASE_STATE="$STATE_ROOT/$1"
	mkdir -p "$CASE_STATE"
	export UCI_STATE="$CASE_STATE"
	reset_env
	OUT="$CASE_STATE/stdout.log"
	ERRLOG="$CASE_STATE/stderr.log"
	: >"$OUT"
	: >"$ERRLOG"
	rm -f "$CASE_STATE/calls.log" "$CASE_STATE/fw.log" "$CASE_STATE/ifup.log" \
		"$CASE_STATE/.ubus_wwan_calls" "$CASE_STATE/.sleep_calls"
	CASE_FAIL_BASE=$FAIL
	printf '\n=== %s — %s\n' "$1" "${2:-}"
}

finish() {
	if [ "$VERBOSE" = "1" ] || [ "$FAIL" -gt "$CASE_FAIL_BASE" ]; then
		printf '  --- stdout ---\n'
		sed 's/^/  | /' "$OUT" 2>/dev/null | head -n 40
		printf '  --- stderr ---\n'
		sed 's/^/  | /' "$ERRLOG" 2>/dev/null | head -n 40
	fi
}

run_setup() {
	PATH="${EXTRA_PATH:+$EXTRA_PATH:}$BINDIR:$PATH" "$SH_BIN" $SH_ARGS "$SETUP_SH" >"$OUT" 2>"$ERRLOG"
	RC=$?
}

run_firstboot() {
	PATH="$BINDIR:$PATH" "$SH_BIN" $SH_ARGS "$FIRSTBOOT_SH" >"$OUT" 2>"$ERRLOG"
	RC=$?
}

# ---- フィクスチャ -------------------------------------------------------
prep_wireless_dual() {
	uciq set wireless.radio0=wifi-device
	uciq set wireless.radio0.band='2g'
	uciq set wireless.radio0.channel='11'
	uciq set wireless.radio0.disabled='1'
	uciq set wireless.radio1=wifi-device
	uciq set wireless.radio1.band='5g'
	uciq set wireless.radio1.channel='36'
	uciq set wireless.radio1.disabled='1'
	uciq set wireless.default_radio0=wifi-iface
	uciq set wireless.default_radio0.device='radio0'
	uciq set wireless.default_radio0.mode='ap'
	uciq set wireless.default_radio0.network='lan'
	uciq set wireless.default_radio0.ssid='OpenWrt'
	uciq set wireless.default_radio0.encryption='none'
	uciq set wireless.default_radio1=wifi-iface
	uciq set wireless.default_radio1.device='radio1'
	uciq set wireless.default_radio1.mode='ap'
	uciq set wireless.default_radio1.network='lan'
	uciq set wireless.default_radio1.ssid='OpenWrt'
	uciq set wireless.default_radio1.encryption='none'
}

prep_wireless_single() { # band
	uciq set wireless.radio0=wifi-device
	uciq set wireless.radio0.band="$1"
	uciq set wireless.radio0.channel='36'
	uciq set wireless.radio0.disabled='1'
	uciq set wireless.default_radio0=wifi-iface
	uciq set wireless.default_radio0.device='radio0'
	uciq set wireless.default_radio0.mode='ap'
	uciq set wireless.default_radio0.network='lan'
	uciq set wireless.default_radio0.ssid='OpenWrt'
	uciq set wireless.default_radio0.encryption='none'
}

prep_network() {
	uciq set network.loopback=interface
	uciq set network.loopback.proto='static'
	uciq set network.loopback.ipaddr='127.0.0.1'
	uciq set network.lan=interface
	uciq set network.lan.proto='static'
	uciq set network.lan.ipaddr='192.168.1.1'
	uciq set network.wan=interface
	uciq set network.wan.proto='dhcp'
	uciq set network.wan.device='eth0'
	uciq set network.wan6=interface
	uciq set network.wan6.proto='dhcpv6'
}

prep_firewall() {
	uciq set firewall.lanzone=zone
	uciq set firewall.lanzone.name='lan'
	uciq set firewall.lanzone.input='ACCEPT'
	uciq set firewall.lanzone.output='ACCEPT'
	uciq set firewall.lanzone.forward='ACCEPT'
	uciq set firewall.lanzone.network='lan'
	uciq set firewall.wanzone=zone
	uciq set firewall.wanzone.name='wan'
	uciq set firewall.wanzone.input='REJECT'
	uciq set firewall.wanzone.output='ACCEPT'
	uciq set firewall.wanzone.forward='REJECT'
	uciq set firewall.wanzone.masq='1'
	uciq set firewall.wanzone.mtu_fix='1'
	uciq set firewall.wanzone.network='wan wan6'
	uciq set firewall.rule1=rule
	uciq set firewall.rule1.name='Allow-DHCP-Renew'
}

prep_firewall_custom() { # name='wan' のゾーンが無い環境
	uciq set firewall.z1=zone
	uciq set firewall.z1.name='lan'
	uciq set firewall.z1.network='lan'
	uciq set firewall.z2=zone
	uciq set firewall.z2.name='internet'
	uciq set firewall.z2.network='wan wan6'
	uciq set firewall.z2.masq='1'
}

prep_firewall_lan_only() {
	uciq set firewall.z1=zone
	uciq set firewall.z1.name='lan'
	uciq set firewall.z1.network='lan'
}

# ==========================================================================
make_wrappers

printf '==========================================================================\n'
printf 'openwrt-setup 検証ハーネス\n'
printf '  setup.sh           : %s\n' "$SETUP_SH"
printf '  99-asu-defaults.sh : %s\n' "$FIRSTBOOT_SH"
printf '  実行シェル         : %s %s\n' "$SH_BIN" "$SH_ARGS"
"$SH_BIN" $SH_ARGS -c 'if [ -n "${BASH_VERSION:-}" ]; then printf "  シェル版           : bash %s\n" "$BASH_VERSION"; elif [ -n "${KSH_VERSION:-}" ]; then printf "  シェル版           : %s\n" "$KSH_VERSION"; else printf "  シェル版           : POSIX sh（ash 系）\n"; fi' 2>/dev/null
printf '  setup.sh sha256    : %s (%s)\n' "$(shasum -a 256 "$SETUP_SH" 2>/dev/null | cut -d' ' -f1)" "$(ls -l "$SETUP_SH" | awk '{print $6" "$7" "$8}')"
printf '  99-... sha256      : %s\n' "$(shasum -a 256 "$FIRSTBOOT_SH" 2>/dev/null | cut -d' ' -f1)"
printf '  sed                : '
if sed --version >/dev/null 2>&1; then printf 'GNU sed\n'; else printf 'BSD sed（macOS）\n'; fi
for c in busybox dash; do
	if command -v "$c" >/dev/null 2>&1; then
		printf '  %-18s : あり (%s)\n' "$c" "$(command -v "$c")"
	else
		printf '  %-18s : なし\n' "$c"
	fi
done
printf '==========================================================================\n'

# ==========================================================================
# a) 正常系
# ==========================================================================
begin a_normal '正常系: radio0=2g / radio1=5g、STA=5g AP=2g'
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0 で終わる' 0
assert_eq 'sta_wan は wifi-iface' wifi-iface "$(field wireless.sta_wan)"
assert_eq 'STA 側デバイスは radio1(5g)' radio1 "$(field wireless.sta_wan.device)"
assert_eq 'sta_wan.mode=sta' sta "$(field wireless.sta_wan.mode)"
assert_eq 'sta_wan.network=wwan' wwan "$(field wireless.sta_wan.network)"
assert_eq 'sta_wan.ssid=SCHOOL_SSID' 'School-WiFi' "$(field wireless.sta_wan.ssid)"
assert_eq 'sta_wan.encryption=wpa2' wpa2 "$(field wireless.sta_wan.encryption)"
assert_eq 'sta_wan.eap_type=peap' peap "$(field wireless.sta_wan.eap_type)"
assert_eq 'sta_wan.identity 入力どおり' 'student@example.ac.jp' "$(field wireless.sta_wan.identity)"
assert_eq 'sta_wan.password 入力どおり' 'secret123' "$(field wireless.sta_wan.password)"
assert_eq 'sta_wan.auth=MSCHAPV2' MSCHAPV2 "$(field wireless.sta_wan.auth)"
assert_eq 'sta_wan.ca_cert_usesystem=1' 1 "$(field wireless.sta_wan.ca_cert_usesystem)"
assert_eq 'sta_wan.ieee80211w=0' 0 "$(field wireless.sta_wan.ieee80211w)"
assert_absent 'EAP_ANON 空なら anonymous_identity を作らない' wireless.sta_wan.anonymous_identity
assert_eq 'radio0.country=JP' JP "$(field wireless.radio0.country)"
assert_eq 'radio1.country=JP' JP "$(field wireless.radio1.country)"
assert_eq 'radio0.disabled=0' 0 "$(field wireless.radio0.disabled)"
assert_eq 'radio1.disabled=0' 0 "$(field wireless.radio1.disabled)"
assert_eq 'AP_CHANNEL 空 → 2g ラジオは 6 を自動選択' 6 "$(field wireless.radio0.channel)"
assert_eq '5g ラジオの channel は保持(36)' 36 "$(field wireless.radio1.channel)"
assert_contains 'AP は既存 AP iface を再利用（ログ）' 'AP側 iface=default_radio0' "$(out_txt)"
assert_eq 'AP.ssid=AP_SSID' 'MyRouter' "$(field wireless.default_radio0.ssid)"
assert_eq 'AP.encryption=psk2' psk2 "$(field wireless.default_radio0.encryption)"
assert_eq 'AP.key=AP_KEY' 'openwrt1234' "$(field wireless.default_radio0.key)"
assert_eq 'AP.disabled=0' 0 "$(field wireless.default_radio0.disabled)"
assert_eq 'STA ラジオ上の AP iface は無効化される' 1 "$(field wireless.default_radio1.disabled)"
assert_absent 'CA_CERT 未指定なら ca_cert を作らない' wireless.sta_wan.ca_cert
assert_absent 'ap_lan セクションは作られない' wireless.ap_lan
assert_eq 'network.wwan=interface' interface "$(field network.wwan)"
assert_eq 'network.wwan.proto=dhcp' dhcp "$(field network.wwan.proto)"
assert_eq 'network.wwan.disabled=0' 0 "$(field network.wwan.disabled)"
assert_eq 'wan ゾーンの masq=1' 1 "$(field firewall.wanzone.masq)"
assert_contains 'wan ゾーンの network に wwan が入る' 'wwan' "$(field firewall.wanzone.network)"
assert_eq 'wwan の重複なし（1 回だけ）' 1 "$(printf '%s\n' "$(field firewall.wanzone.network)" | grep -c '^wwan$' || true)"
assert_contains 'wan ゾーン判定のログ' 'wan ゾーン=wanzone に wwan を追加' "$(out_txt)"
assert_eq 'wireless のセクション数は 5 のまま（増殖なし）' 5 "$(show_n wireless '=wifi-')"
assert_contains 'wifi reload が呼ばれる' 'wifi reload' "$(calls)"
assert_contains 'firewall restart が呼ばれる' 'restart' "$(fwl)"
assert_contains '成功ログに IP が出る' 'OK: 学校Wi-Fiに接続しました (IP: 192.0.2.10)' "$(out_txt)"
finish

# --------------------------------------------------------------------------
begin a2_scratch '正常系(2): /etc/config/wireless が無い状態から生成させる'
prep_firewall
run_setup
assert_rc 'exit 0 で終わる' 0
assert_contains '生成メッセージを出す' '/etc/config/wireless が無いので生成します' "$(out_txt)"
assert_contains 'wifi config が呼ばれる' 'wifi config' "$(calls)"
assert_eq 'radio0/radio1 が生成される' 2 "$(show_n wireless '=wifi-device')"
assert_eq 'sta_wan.device=radio1' radio1 "$(field wireless.sta_wan.device)"
assert_eq 'AP は生成された default_radio0 を再利用' 'MyRouter' "$(field wireless.default_radio0.ssid)"
assert_eq 'AP.key' 'openwrt1234' "$(field wireless.default_radio0.key)"
assert_absent 'ap_lan は作られない（既存 AP があるため）' wireless.ap_lan
finish

# --------------------------------------------------------------------------
begin a3_apiface_robust 'ap_iface_on(): device/mode が欠けた iface があっても壊れない'
prep_wireless_dual
prep_network
prep_firewall
uciq set wireless.broken=wifi-iface
uciq set wireless.broken.mode='ap'
uciq set wireless.bogus=wifi-iface
uciq set wireless.bogus.device='radio0'
run_setup
assert_rc 'exit 0 で終わる（for ループが止まらない）' 0
assert_lacks 'stderr に uci の生エラーが出ない' 'uci:' "$(err_txt)"
assert_lacks 'stderr に shell のエラーが出ない' 'not found' "$(err_txt)"
assert_eq 'AP iface は default_radio0 のまま' 'MyRouter' "$(field wireless.default_radio0.ssid)"
assert_eq '壊れた iface(broken) は触らない' '' "$(field wireless.broken.ssid)"
assert_eq 'STA 側も正しく設定される' radio1 "$(field wireless.sta_wan.device)"
finish

# ==========================================================================
# b) 冪等性
# ==========================================================================
begin b_idempotent '冪等性: 2 回実行しても設定が増えない'
prep_wireless_dual
prep_network
prep_firewall
run_setup
RC1=$RC
"$BINDIR/uci" show >"$CASE_STATE/show1.txt" 2>/dev/null
run_setup
RC2=$RC
"$BINDIR/uci" show >"$CASE_STATE/show2.txt" 2>/dev/null
assert_eq '1 回目 exit 0' 0 "$RC1"
assert_eq '2 回目 exit 0' 0 "$RC2"
if cmp -s "$CASE_STATE/show1.txt" "$CASE_STATE/show2.txt"; then
	ok '2 回目の uci show が 1 回目と完全一致'
else
	bad '2 回目の uci show が 1 回目と一致しない'
	diff -u "$CASE_STATE/show1.txt" "$CASE_STATE/show2.txt" 2>/dev/null | head -n 20
fi
assert_eq 'wan ゾーンの network に wwan が 1 つだけ' 1 "$(printf '%s\n' "$(field firewall.wanzone.network)" | grep -c '^wwan$' || true)"
assert_eq 'sta_wan は 1 つだけ' 1 "$(show_n wireless '\.sta_wan=')"
assert_eq 'AP iface は増えない（default_radio0/1 + sta_wan = 3）' 3 "$(show_n wireless '=wifi-iface')"
assert_eq 'wireless セクション総数 5' 5 "$(show_n wireless '=wifi-')"
finish

# --------------------------------------------------------------------------
begin b2_stale_sta_wan '冪等性(2): 古い sta_wan（別 device・残骸 option）を上書きする'
prep_wireless_dual
prep_network
prep_firewall
uciq set wireless.sta_wan=wifi-iface
uciq set wireless.sta_wan.device='radio0'
uciq set wireless.sta_wan.mode='sta'
uciq set wireless.sta_wan.ssid='old-ssid'
uciq set wireless.sta_wan.anonymous_identity='stale@example'
run_setup
assert_rc 'exit 0' 0
assert_eq 'device が radio1 に更新される' radio1 "$(field wireless.sta_wan.device)"
assert_eq 'ssid が更新される' 'School-WiFi' "$(field wireless.sta_wan.ssid)"
assert_absent '残骸 anonymous_identity が消える（delete→再作成の証拠）' wireless.sta_wan.anonymous_identity
finish

# --------------------------------------------------------------------------
begin b3_foreign_sta '冪等性(3): 名前が違う既存 STA iface の扱い'
prep_wireless_dual
prep_network
prep_firewall
uciq set wireless.old_sta=wifi-iface
uciq set wireless.old_sta.device='radio1'
uciq set wireless.old_sta.mode='sta'
uciq set wireless.old_sta.ssid='old-school'
run_setup
n=$(show_n wireless "mode='sta'")
assert_eq 'STA iface は 1 つに収まる' 1 "$n"
assert_absent '別名の既存 STA iface は削除される' wireless.old_sta
assert_contains '削除したことをログに出す' '既存の STA iface (old_sta) を削除しました' "$(out_txt)"
finish

# ==========================================================================
# c) 特殊文字
# ==========================================================================
begin c_special_chars '特殊文字: パスワード/SSID に 空白 & $ " と シングルクォートを含む'
SPECIAL_PW='p'"'"'a"$d e&f\g#h`i;j'
SPECIAL_SSID='学校 '"'"'A&B'"'"' $x'
export EAP_PASSWORD="$SPECIAL_PW"
export SCHOOL_SSID="$SPECIAL_SSID"
export AP_KEY="$SPECIAL_PW"
export AP_SSID="$SPECIAL_SSID"
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0' 0
assert_eq 'sta_wan.password が 1 文字も化けない' "$SPECIAL_PW" "$(field wireless.sta_wan.password)"
assert_eq 'sta_wan.ssid が 1 文字も化けない' "$SPECIAL_SSID" "$(field wireless.sta_wan.ssid)"
assert_eq 'AP.key が 1 文字も化けない' "$SPECIAL_PW" "$(field wireless.default_radio0.key)"
assert_eq 'AP.ssid が 1 文字も化けない' "$SPECIAL_SSID" "$(field wireless.default_radio0.ssid)"
assert_eq 'sta_wan.identity も壊れない' 'student@example.ac.jp' "$(field wireless.sta_wan.identity)"
assert_absent '不要な option が混入しない' wireless.sta_wan.anonymous_identity
"$BINDIR/uci" show wireless >"$CASE_STATE/show1.txt" 2>/dev/null
run_setup
RC2=$RC
"$BINDIR/uci" show wireless >"$CASE_STATE/show2.txt" 2>/dev/null
assert_eq '特殊文字入りでも 2 回目 exit 0' 0 "$RC2"
if cmp -s "$CASE_STATE/show1.txt" "$CASE_STATE/show2.txt"; then
	ok '特殊文字入りでも 2 回目が完全一致（シェル再展開で化けない）'
else
	bad '特殊文字入りで 2 回目の結果が変わる'
	diff -u "$CASE_STATE/show1.txt" "$CASE_STATE/show2.txt" 2>/dev/null | head -n 20
fi
# 生成された show 行を実際に shell として eval し、値が戻るか（quoting の検証）
LINE=$(grep -F 'wireless.sta_wan.password=' "$CASE_STATE/show2.txt" 2>/dev/null | head -n 1)
if [ -n "$LINE" ]; then
	VALPART=${LINE#*=}
	eval "PARSED=$VALPART" 2>/dev/null
	assert_eq 'show の行を shell で再パースしても値が一致' "$SPECIAL_PW" "$PARSED"
else
	bad 'password の show 行が見つからない'
fi
finish

# --------------------------------------------------------------------------
begin c2_eap_conditional '条件付き option: EAP_AUTH 空 / EAP_ANON 有り / EAP_TYPE=ttls'
export EAP_AUTH=''
export EAP_ANON='anon@example.ac.jp'
export EAP_TYPE='ttls'
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0' 0
assert_absent 'EAP_AUTH が空なら auth を作らない' wireless.sta_wan.auth
if [ "$(field wireless.sta_wan.auth)" = "MSCHAPV2" ]; then
	bug "EAP_TLS 用に EAP_AUTH='' を渡しても、\${EAP_AUTH:-MSCHAPV2} の既定値展開で MSCHAPV2 になる（EAP-TLS 構成が作れない: setup.sh:27,124）"
fi
assert_eq 'EAP_ANON があれば anonymous_identity を作る' 'anon@example.ac.jp' "$(field wireless.sta_wan.anonymous_identity)"
assert_eq 'EAP_TYPE=ttls が反映される' ttls "$(field wireless.sta_wan.eap_type)"
finish

# ==========================================================================
# d) 異常系: band=5g の無線デバイスが無い
# ==========================================================================
begin d_no_5g '異常系: 5g ラジオが無い → 明確なエラーで exit 1'
prep_wireless_single '2g'
prep_network
prep_firewall
run_setup
assert_rc 'exit 1 で止まる' 1
assert_contains 'エラー本文（band とヒント）' 'band=5g の無線デバイスが見つかりません（'"'"'uci show wireless'"'"' を確認）' "$(err_txt)"
assert_absent 'sta_wan を作らない（半端な設定を残さない）' wireless.sta_wan
assert_absent 'network.wwan も作らない' network.wwan
assert_eq '既存設定を壊さない（radio0.band のまま）' 2g "$(field wireless.radio0.band)"
assert_lacks '余計なスタックトレースを出さない' 'line ' "$(err_txt)"
finish

# --------------------------------------------------------------------------
begin d2_no_2g '異常系(2): 2g ラジオが無い → AP 側で die'
prep_wireless_single '5g'
prep_network
prep_firewall
run_setup
assert_rc 'exit 1' 1
assert_contains 'AP 側のエラー本文' 'band=2g の無線デバイスが見つかりません' "$(err_txt)"
assert_absent 'sta_wan を作らない' wireless.sta_wan
finish

# ==========================================================================
# e) ゾーン名が wan でない環境（@zone[1] フォールバック）
# ==========================================================================
begin e_zone_fallback 'ゾーン: name=wan のゾーンが無い → network から wan ゾーンを特定して wwan を追加'
prep_wireless_dual
prep_network
prep_firewall_custom
run_setup
assert_rc 'exit 0' 0
assert_eq '名前でなく network から internet ゾーンを特定' internet "$(field firewall.z2.name)"
assert_contains 'internet ゾーンの network に wwan が入る' 'wwan' "$(field 'firewall.@zone[1].network')"
assert_eq 'internet ゾーンの masq=1' 1 "$(field firewall.z2.masq)"
assert_eq 'lan ゾーンの network は変わらない' lan "$(field firewall.z1.network)"
assert_contains '選んだゾーンがログに出る' 'wan ゾーン=z2 に wwan を追加' "$(out_txt)"
assert_lacks 'network で特定できたので末尾フォールバックの警告は出ない' '末尾のゾーン' "$(err_txt)"
assert_eq 'wwan は 1 回だけ（リスト重複なし）' 1 "$(printf '%s\n' "$(field firewall.z2.network)" | grep -c '^wwan$' || true)"
finish

# --------------------------------------------------------------------------
begin e2_single_zone 'ゾーン: ゾーンが 1 個だけ（lan しか無い）→ 混入させず die する'
prep_wireless_dual
prep_network
prep_firewall_lan_only
run_setup
assert_eq 'exit 1（wan ゾーンが無いので中断する）' 1 "$RC"
assert_contains 'エラー本文' 'wan ゾーンが見つかりません' "$(err_txt)"
assert_lacks 'lan ゾーンに wwan を混ぜない' 'wwan' "$(field firewall.z1.network)"
assert_eq 'lan ゾーンに masq を立てない' '' "$(field firewall.z1.masq)"
finish

# ==========================================================================
# f) wwan が up にならない
# ==========================================================================
begin f_wwan_never_up '異常系: wwan が up にならない → exit 1 + ログ案内'
export MOCK_WWAN_UP=0
export WAIT_WAN=6
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 1' 1
assert_contains '再実行を促すメッセージ' 'wwan が up になりませんでした。次のログを確認してください:' "$(err_txt)"
assert_contains 'EAP 関連ログを案内する' 'EAP-FAILURE' "$(out_txt)"
assert_contains 'wifi status も出す' '--- wifi status ---' "$(out_txt)"
assert_eq '待ちループは WAIT_WAN 秒で打ち切る（sleep 3 回）' 3 "$(sleeps)"
assert_eq 'ubus 呼び出しも 3 回で打ち切る' 3 "$(ubus_n)"
assert_eq '設定自体は commit まで進む（sta_wan は書かれている）' 1 "$(show_n wireless "ssid='School-WiFi'")"
finish

# --------------------------------------------------------------------------
begin f2_up_but_no_address '異常系(2): up だが address が取れない → IP は「取得中」'
export MOCK_WWAN_ADDR=''
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0（up ならエラーにしない）' 0
assert_contains 'IP が無い場合は「取得中」と出す' 'IP: 取得中' "$(out_txt)"
finish

# ==========================================================================
# 9) 反映まわりの異常系
# ==========================================================================
begin g_fw_restart_fail 'firewall restart が失敗 → warn のみで継続'
export FW_INIT="$BINDIR/firewall-init-fail"
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0 のまま' 0
assert_contains 'WARN が出る' 'firewall の再起動に失敗しました' "$(err_txt)"
assert_contains 'restart は試みている' '(fail)' "$(fwl)"
finish

# --------------------------------------------------------------------------
begin h_fw_missing 'firewall init が無い環境 → 何もせず継続'
export FW_INIT="$WORK/no-such-firewall"
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0' 0
assert_lacks 'firewall の警告は出ない' 'firewall' "$(err_txt)"
finish

# --------------------------------------------------------------------------
begin i_delayed_up 'wwan が遅れて up する → 待って成功する'
export MOCK_WWAN_UP_AFTER=3
export WAIT_WAN=20
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0' 0
assert_contains '成功ログ' 'OK: 学校Wi-Fiに接続しました (IP: 192.0.2.10)' "$(out_txt)"
assert_eq 'up まで待つ（sleep 2 回）' 2 "$(sleeps)"
assert_eq 'ubus 呼び出しは 4 回（3 回目で up + IP 取得 1 回）' 4 "$(ubus_n)"
finish

# ==========================================================================
# k) バンド設定の組み合わせ
# ==========================================================================
begin k_same_radio 'バンド: STA と AP が同じラジオ → warn して続行'
export STA_BAND=2g
export AP_BAND=2g
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0' 0
assert_contains '同じラジオの警告' 'STA と AP が同じラジオ (radio0)' "$(err_txt)"
assert_eq 'STA は radio0' radio0 "$(field wireless.sta_wan.device)"
assert_eq 'AP は radio0 上の default_radio0' 'MyRouter' "$(field wireless.default_radio0.ssid)"
finish

# --------------------------------------------------------------------------
begin k2_band_auto 'バンド: AP_BAND=5g で AP_CHANNEL 未指定 → auto'
export AP_BAND=5g
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0' 0
assert_eq '5g ラジオの channel は auto' auto "$(field wireless.radio1.channel)"
assert_contains '同一ラジオの警告（STA=AP=5g）' 'STA と AP が同じラジオ (radio1)' "$(err_txt)"
finish

# --------------------------------------------------------------------------
begin k3_band_chan_guard 'バンド: AP_BAND=5g + AP_CHANNEL=6（2g 用）→ auto に矯正'
export AP_BAND=5g
export AP_CHANNEL=6
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0' 0
assert_eq '2g 用チャネルは書かれない（auto へ）' auto "$(field wireless.radio1.channel)"
assert_contains '矯正したことを警告する' '5g ラジオに 2.4GHz 用チャネル(6)は使えません' "$(err_txt)"
finish

# --------------------------------------------------------------------------
begin m_wifi_config_fail '異常系: wifi config が失敗して無線設定が生成されない'
export MOCK_WIFI_CONFIG_FAIL=1
export WAIT_WIFI=3
export WAIT_WAN=4
run_setup
assert_rc 'exit 1' 1
assert_contains 'エラー本文' "無線設定が生成されませんでした（'wifi config' を手で実行してください）" "$(err_txt)"
assert_eq 'WAIT_WIFI 回 + 最後の 1 回 = 4 回 sleep する' 4 "$(sleeps)"
assert_eq 'wifi config は 2 回試す（70-83 行）' 2 "$(grep -c '^wifi config' "$CASE_STATE/calls.log" 2>/dev/null || printf '0')"
finish

# ==========================================================================
# n) network 反映（静止的欠陥の実証）
# ==========================================================================
begin n_network_apply '反映: commit 後に ifup wwan で netifd を起こす（回帰テスト）'
export MOCK_WWAN_REQUIRES_IFUP=1
export WAIT_WAN=4
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'ifup が効いて exit 0' 0
assert_contains 'ifup wwan が呼ばれる' 'wwan' "$(cat "$CASE_STATE/ifup.log" 2>/dev/null || printf '')"
assert_contains '接続成功ログ' 'OK: 学校Wi-Fiに接続しました' "$(out_txt)"
finish

# --------------------------------------------------------------------------
begin n2_ifup_missing '反映: ifup コマンド自体が無い環境'
export MOCK_WWAN_REQUIRES_IFUP=1
export IFUP="$WORK/no-such-ifup"
export WAIT_WAN=4
prep_wireless_dual
prep_network
prep_firewall
run_setup
if [ "$RC" = "1" ]; then
	ok 'exit 1（wwan が上がらないため）'
	note 'ifup が無いこと自体は警告されない（EAP ログを案内するので原因を誤認しうる）'
else
	ok "exit $RC"
fi
finish

# ==========================================================================
# o) 証明書と wpad の前提チェック
# ==========================================================================
begin o_ca_cert 'CA_CERT 指定時は ca_cert を使い ca_cert_usesystem=0'
export CA_CERT='/etc/ssl/school-ca.pem'
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0' 0
assert_eq 'ca_cert が入る' '/etc/ssl/school-ca.pem' "$(field wireless.sta_wan.ca_cert)"
assert_eq 'ca_cert_usesystem=0' 0 "$(field wireless.sta_wan.ca_cert_usesystem)"
assert_contains 'ログに出す' 'クライアント証明書CA: /etc/ssl/school-ca.pem' "$(out_txt)"
finish

# --------------------------------------------------------------------------
begin o2_wpad_ng '前提: EAP 非対応の wpad-basic が入っている → die'
mkdir -p "$WORK/wpadng"
cat >"$WORK/wpadng/opkg" <<'EOS'
#!/bin/sh
case "${1:-}" in
	list-installed) printf 'wpad-basic-mbedtls - 2024-01-01\n' ;;
esac
exit 0
EOS
chmod +x "$WORK/wpadng/opkg"
export EXTRA_PATH="$WORK/wpadng"
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 1' 1
assert_contains 'EAP 非対応を明示する' 'EAP 非対応の wpad-basic-mbedtls' "$(err_txt)"
assert_absent '設定を書く前に止まる' wireless.sta_wan
finish

# --------------------------------------------------------------------------
begin o3_wpad_ok '前提: wpad-mbedtls が入っている → 続行'
mkdir -p "$WORK/wpadok"
cat >"$WORK/wpadok/opkg" <<'EOS'
#!/bin/sh
case "${1:-}" in
	list-installed) printf 'wpad-mbedtls - 2024-01-01\n' ;;
esac
exit 0
EOS
chmod +x "$WORK/wpadok/opkg"
export EXTRA_PATH="$WORK/wpadok"
prep_wireless_dual
prep_network
prep_firewall
run_setup
assert_rc 'exit 0' 0
assert_contains '使う wpad をログに出す' 'wpad=wpad-mbedtls' "$(out_txt)"
finish

# ==========================================================================
# j) 初回起動スクリプト（99-asu-defaults.sh）
# ==========================================================================
begin j99_fresh '初回起動: 設定が空の状態から AP を有効化する'
run_firstboot
assert_rc 'exit 0' 0
assert_eq 'wifi config で無線設定が生成される' 2 "$(show_n wireless '=wifi-device')"
assert_eq '2g(radio0) が有効化される' 0 "$(field wireless.radio0.disabled)"
assert_eq 'country=JP' JP "$(field wireless.radio0.country)"
assert_eq 'AP iface が有効化される' 0 "$(field wireless.default_radio0.disabled)"
assert_eq 'AP ssid=OpenWrt-Setup' 'OpenWrt-Setup' "$(field wireless.default_radio0.ssid)"
assert_eq 'AP key=openwrt1234' 'openwrt1234' "$(field wireless.default_radio0.key)"
assert_eq 'AP encryption=psk2' psk2 "$(field wireless.default_radio0.encryption)"
assert_contains 'wifi up が呼ばれる' 'wifi up' "$(calls)"
assert_eq '5g ラジオは触らない（disabled=1 のまま）' 1 "$(field wireless.radio1.disabled)"
finish

# --------------------------------------------------------------------------
begin j99_twice '初回起動: 2 回実行しても壊れない'
run_firstboot
"$BINDIR/uci" show >"$CASE_STATE/show1.txt" 2>/dev/null
run_firstboot
"$BINDIR/uci" show >"$CASE_STATE/show2.txt" 2>/dev/null
assert_rc '2 回目も exit 0' 0
if cmp -s "$CASE_STATE/show1.txt" "$CASE_STATE/show2.txt"; then
	ok '2 回目も設定が完全一致'
else
	bad '2 回目で設定が変わる'
	diff -u "$CASE_STATE/show1.txt" "$CASE_STATE/show2.txt" 2>/dev/null | head -n 20
fi
assert_eq 'セクションは増えない' 2 "$(show_n wireless '=wifi-device')"
finish

# --------------------------------------------------------------------------
begin j99_no_2g '初回起動: 2g ラジオが無い端末 → 何もせず警告を出す'
export MOCK_RADIOS="radio0:5g"
run_firstboot
assert_rc 'exit 0' 0
assert_eq '5g の AP は有効化しない' 1 "$(field wireless.radio0.disabled)"
assert_contains '2g が無いことを stderr で知らせる' '2.4GHz ラジオが見つかりません' "$(err_txt)"
finish

# --------------------------------------------------------------------------
begin j99_existing '初回起動: 既に AP 設定がある状態（wifi config を呼ばない）'
prep_wireless_dual
run_firstboot
assert_rc 'exit 0' 0
assert_lacks 'wifi config は呼ばれない（7 行目の早期脱出）' 'wifi config' "$(calls)"
assert_eq '既存 AP iface の ssid を上書きする' 'OpenWrt-Setup' "$(field wireless.default_radio0.ssid)"
assert_eq '既存 AP iface の key を上書きする' 'openwrt1234' "$(field wireless.default_radio0.key)"
finish

# --------------------------------------------------------------------------
begin j99_sta_on_2g '初回起動: 2g 側に STA iface がある場合の巻き添え'
prep_wireless_dual
uciq set wireless.sta_wan=wifi-iface
uciq set wireless.sta_wan.device='radio0'
uciq set wireless.sta_wan.mode='sta'
uciq set wireless.sta_wan.ssid='school-ssid'
uciq set wireless.sta_wan.encryption='wpa2'
uciq set wireless.sta_wan.key='dummy'
run_firstboot
assert_rc 'exit 0' 0
assert_eq 'STA iface の ssid は巻き添えにならない' 'school-ssid' "$(field wireless.sta_wan.ssid)"
assert_absent 'STA iface に触らない（disabled は未設定のまま）' wireless.sta_wan.disabled
finish

# ==========================================================================
# z) 構文チェック
# ==========================================================================
begin z_syntax '構文チェック: sh -n で全スクリプトをパース'
syn() { # file
	if "$SH_BIN" $SH_ARGS -n "$1" 2>"$CASE_STATE/syn.err"; then
		ok "sh -n $(basename "$1")"
	else
		bad "sh -n $(basename "$1")"
		sed 's/^/          /' "$CASE_STATE/syn.err" | head -n 5
	fi
}
syn "$SETUP_SH"
syn "$FIRSTBOOT_SH"
for f in "$MOCKS"/*; do
	syn "$f"
done
syn "$HERE/run_tests.sh"
finish

# ==========================================================================
printf '\n==========================================================================\n'
printf '結果: PASS=%s  FAIL=%s  BUG(注記)=%s\n' "$PASS" "$FAIL" "$BUG"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFAIL 一覧:%s\n' "$FAILNOTES"
fi
if [ "$BUG" -gt 0 ]; then
	printf '\nBUG 一覧（既知の欠陥・要修正）:%s\n' "$BUGNOTES"
fi
printf '==========================================================================\n'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
