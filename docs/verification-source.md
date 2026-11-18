# setup.sh ソース裏取り（OpenWrt 25.12 / openwrt-25.12 ブランチ）

対象スクリプト: `~/openwrt-setup/setup.sh`（読み取り専用・編集していない）
参照ソース: https://github.com/openwrt/openwrt ブランチ `openwrt-25.12`
  - head commit `08379a3a86bd6075cca11ed4203e91b77db9e6bc`（tree `a2c58426eb171d5126b27a07bab5f8794843c0d9`）
  - firewall4 は別リポジトリ: https://github.com/openwrt/firewall4 commit `b6e5157527d361f99ad52eaa6da273cb0f2dfd59`
  - 取得方法: raw.githubusercontent.com でファイル単位に取得し、ローカルで grep（下記の行番号はこの commit のもの）

機器: ELECOM WRC-1167GHBK2-S（`target/linux/ramips/image/mt7621.mk:1316-1326`、MT7621A + MT7615D）
目的: 学校の WPA2-Enterprise に STA 接続し、自前 SSID で NAT 再放出

---

## 0. 先に読むべき前提: 25.12 は ucode 実装が既定

`package/network/config/wifi-scripts/Makefile:48-50`

```make
ifeq ($(CONFIG_WIFI_SCRIPTS_UCODE),y)
	$(CP) ./files-ucode/* $(1)/
endif
```

`files-ucode/` が `files/` の上にコピーされるため、既定ビルドでは

- `/lib/netifd/wireless/mac80211.sh` … **ucode 版**（`files-ucode/lib/netifd/wireless/mac80211.sh`、356 行、`#!/usr/bin/ucode`）
- `/lib/netifd/hostapd.sh` … POSIX sh 版（`files/lib/netifd/hostapd.sh`）は**残るが STA/AP の主経路ではない**

ucode 側の実体:

| 役割 | ファイル |
|---|---|
| 無線設定の解釈（encryption→auth_type 等） | `files-ucode/usr/share/ucode/wifi/iface.uc` |
| wpa_supplicant.conf 生成 | `files-ucode/usr/share/ucode/wifi/supplicant.uc` |
| hostapd.conf 生成 | `files-ucode/usr/share/ucode/wifi/hostapd.uc` / `ap.uc` |
| UCI→config 変換・alias | `package/network/config/netifd/files/lib/netifd/utils.uc`（`/usr/lib/netifd/utils.uc`）、`files-ucode/usr/share/ucode/wifi/validate.uc` |

以下では「ucode（既定）」と「shell（旧経路）」の両方を並記する。挙動が一致している項目は OK と判定した。

---

## 1. 判定サマリ

| # | 検証項目 | 判定 | 要点 |
|---|---|---|---|
| 1 | `option encryption 'wpa2'` が STA で EAP になるか | **OK** | ucode/shell 双方で `auth_type=eap` |
| 2 | `option auth 'MSCHAPV2'` と `'EAP-MSCHAPV2'` の等価性・phase2 組み立て | **OK** | どちらも `phase2="auth=MSCHAPV2"` |
| 3 | `ca_cert_usesystem` の前提条件 | **OK（条件付き）** | `/etc/ssl/certs/ca-certificates.crt` の実在が条件。既定イメージには ca-bundle が入るので満たされる。ただし私設 CA なら検証失敗 |
| 4 | `ieee80211w`（PMF=0 既定） | **NG** | 0 は「任意」ではなく **PMF 無効**。コメントも誤り。PMF 必須の学内 AP で assoc 拒否 |
| 5 | `option network 'wwan'` の束縛 | **OK** | `wireless-device.uc` の `interface_handle_link` が実体。`wwan` を disabled=0 にする現状の処理は必須で正しい |
| 6 | `band` / `channel` / `country` / `disabled` の意味論 | **OK（注意付き）** | `country` は `country_code` の alias。5GHz は国コード必須（OpenWrt 自身が未設定時 5GHz 既定 AP を disabled で生成） |
| 7 | AP+STA 同時（別ラジオ） | **OK** | 別ラジオなら wds/multi_ap 不要。同一ラジオのみ `start_disabled` の影響あり（スクリプトは警告済み） |
| 8 | firewall4 で wan ゾーンに `wwan` を足す方法 | **OK** | `list network 'wwan'` は fw4 の設計どおり。`masq=1` は冗長、`@zone[1]` フォールバックは脆い |
| 9 | **追加**: wpad が EAP 対応版か（前提） | **NG 候補（要確認）** | ramips 既定は `wpad-basic-mbedtls` = **EAP 非対応**。これだと項目 1〜3 が全部無意味になる |

---

## 2. 各項目の根拠

### 項目 1: `encryption 'wpa2'` → EAP（OK）

**ucode（既定）** `files-ucode/usr/share/ucode/wifi/iface.uc:13-14`（`wpa=2` 付与）と `:78-82`:

```ucode
	case 'wpa':
	case 'wpa2':
	case 'wpa-mixed':
		config.auth_type = 'eap';
```

`iface.uc:122` で `config.wpa_pairwise ??= 'CCMP'`。

**shell（旧経路）** `files/lib/netifd/netifd-wireless.sh:293-296`（`wireless_vif_parse_encryption`、関数は `:211`）:

```sh
	*psk*) auth_type=psk ;;            # :293  ← psk2 はこちらに先に一致
	*wpa*|*8021x*) auth_type=eap ;;    # :295-296
```

`:257` で `wpa2*|wpa3*|*psk2*|psk3*|sae*|owe*) wpa=2`。

→ どちらの実装でも `encryption 'wpa2'`（STA）は **auth_type=eap / key_mgmt=WPA-EAP / proto=RSN** になり、WPA2-Enterprise として動く。setup.sh L114 の指定は正しい。

### 項目 2: PEAP 展開・phase2・`MSCHAPV2` と `EAP-MSCHAPV2`（OK）

**ucode（既定）** `files-ucode/usr/share/ucode/wifi/supplicant.uc:145-175`:

```ucode
	case 'eap':
	...
151		if (config.ca_cert_usesystem && fs.stat('/etc/ssl/certs/ca-certificates.crt'))
152			config.ca_cert = '/etc/ssl/certs/ca-certificates.crt';
154		const eap_method_map = { fast: 'FAST', peap: 'PEAP', ttls: 'TTLS', tls: 'TLS' };
155		if (eap_method_map[config.eap_type])
156			config.eap = eap_method_map[config.eap_type];
...
162			set_default(config, 'auth', 'MSCHAPV2');
164			let auth = config.auth;
165			let phase2proto = 'auth=';
166			if (index(auth, 'auth') == 0) {
167				/* user already provided a full "auth=..." spec */
168				phase2proto = '';
169			} else if (index(auth, 'EAP-') == 0) {
170				/* inner EAP method, e.g. EAP-MSCHAPV2 -> MSCHAPV2 */
171				auth = substr(auth, 4);
172				if (config.eap_type == 'ttls')
173					phase2proto = 'autheap=';
174			}
175			config.phase2 = `"${phase2proto}${auth}"`;
```

検算:

| `option auth` | eap_type | phase2 |
|---|---|---|
| `MSCHAPV2` | peap | `"auth=MSCHAPV2"` |
| `EAP-MSCHAPV2` | peap | `"auth=MSCHAPV2"`（**等価**） |
| `MSCHAPV2` | ttls | `"auth=MSCHAPV2"`（TTLS でも非 EAP 内側は auth=） |
| `EAP-MSCHAPV2` | ttls | `"autheap=MSCHAPV2"` |
| `auth=MSCHAPV2` | 任意 | `"auth=MSCHAPV2"`（前置き済み形式も許容） |
| 未設定 | peap | `"auth=MSCHAPV2"`（`set_default`） |

出力は `supplicant.uc:221-237`。`password` / `identity` / `anonymous_identity` は `network_append_string_vars` 経由で **ダブルクォート付き**、`eap` / `phase2` / `key_mgmt` は素の `key=value`（`files-ucode/usr/share/ucode/wifi/common.uc:70-73, 80-105`、文字列のエスケープは同 `:55-61`）。

**shell（旧経路）** `files/lib/netifd/hostapd.sh` も同一結果:

```sh
1441	json_get_vars eap_type identity anonymous_identity ca_cert ca_cert_usesystem
1444	if [ "$ca_cert_usesystem" -eq "1" -a -f "/etc/ssl/certs/ca-certificates.crt" ]; then
1490		set_default auth MSCHAPV2
1502		append network_data "password=\"$password\""     # fast/peap/ttls 分岐内
1535		phase2proto="auth="
1537-1538	"auth"*) phase2proto="" ;;
1540-1543	"EAP-"*) auth="$(echo $auth | cut -b 5- )"; [ "$eap_type" = "ttls" ] && phase2proto="autheap=" ;;
1575		append network_data "phase2=\"$phase2proto$auth\""
1578		append network_data "eap=$(echo $eap_type | tr 'a-z' 'A-Z')"
```

`option password` が効く根拠（UCI 属性名の解決）: schema 上のキーが `"password:wpakey"` 形式で、`package/network/config/netifd/files/lib/netifd/utils.uc:74-85` が `split(cur[0], ":", 2)` して **`password` を属性名として登録**する。

```ucode
77	for (let cur in data) {
78		let name_data = split(cur[0], ":", 2);
79		let name = name_data[0];
80		ret[name] = cur[1];
```

同 `:87-101` の `parse_attribute_list` が UCI の値をそのまま拾う。`option password` / `option wpakey` の双方が受ける（`wpakey` は validate マップで別名登録）。

→ setup.sh L116-121（eap_type/identity/password/auth/anonymous_identity）は正しい。`EAP_TYPE=peap` + `EAP_AUTH=MSCHAPV2` が最も一般的な学内 PEAP 構成。

### 項目 3: `ca_cert_usesystem` の前提（OK・条件付き）

条件は **`/etc/ssl/certs/ca-certificates.crt` が実在すること**だけ。

- ucode: `supplicant.uc:151-152`（`fs.stat` が真のときだけ `ca_cert` を設定。偽なら**無言でスキップ**）
- shell: `hostapd.sh:1444`（`-f` テスト）

このファイルを置くのは `ca-bundle` パッケージ:

`package/system/ca-certificates/Makefile:66-70`

```make
define Package/ca-bundle/install
	$(INSTALL_DIR) $(1)/etc/ssl/certs
	cat $(PKG_INSTALL_DIR)/usr/share/ca-certificates/*/*.crt >$(1)/etc/ssl/certs/ca-certificates.crt
	$(LN) /etc/ssl/certs/ca-certificates.crt $(1)/etc/ssl/cert.pem
endef
```

`ca-bundle` は既定パッケージに入っている:

`include/target.mk:21-23`

```make
DEFAULT_PACKAGES:=\
	base-files \
	ca-bundle \
```

→ **既定イメージなら前提は自動的に満たされる**（`ramips/mt7621` の `target.mk` も `DEFAULT_PACKAGES +=` で追加するだけで、ca-bundle を外していない）。

注意点（スクリプト側の改善余地）:

1. `CA_USESYSTEM=0` にすると `ca_cert` 無し → wpa_supplicant は**サーバ証明書を検証しない**。`setup.sh:29` のコメント「0=検証しない」は正しいが、リスクの明示が弱い。既定 1 は妥当。
2. 学内 RADIUS が**私設 CA**（大学独自 CA）で署名している場合、ca-bundle には入っていないので検証失敗 → EAP が失敗する。その場合は `option ca_cert '/path/to/school-ca.pem'` を渡す必要がある。現状スクリプトに `ca_cert` 直接指定の口が無い。

### 項目 4: `ieee80211w`（NG）

schema `files-ucode/usr/share/schema/wireless.wifi-iface.json`:

```json
"ieee80211w": {
  "description": "Enables MFP (802.11w) support (0 = disabled, 1 = optional, 2 = required). Requires the 'full' version of wpad/hostapd and support from the Wi-Fi driver",
  "type": "number", "enum": [0, 1, 2]
}
```

つまり **0 = PMF 無効 / 1 = optional / 2 = required**。setup.sh L30 のコメント「0=任意 1=必須 2=必須(強制)」は**誤り**（0 と 1 の意味がずれている）。

UCI 値はそのまま wpa_supplicant に渡る（EAP は強制変換の対象外）:

`supplicant.uc:63-66`

```ucode
	if (config.auth_type in ['sae', 'owe', 'eap2', 'eap192'])
		config.ieee80211w = 2;
	else if (config.auth_type in ['psk-sae'] && !config.ieee80211w)
		config.ieee80211w = 1;
```

`auth_type` は `eap`（項目 1）なので**何も強制されず PMF=0 がそのまま効く**。

key_mgmt 側: PMF>0 のときだけ AKM に SHA256 が足される（`iface.uc:139-145`、shell は `hostapd.sh:47`）。
conf 出力: `hostapd.sh:1597-1600` の `case "$ieee80211w" in [012]) [ "$wpa" -ge 2 ] && append ... "ieee80211w=$ieee80211w"`（ucode 側も同様に出力）。

**影響**: 学内 AP が「PMF required（802.11w 必須）」の WPA2-Enterprise だと assoc が拒否され、`setup.sh` の wwan up 待ち（L166-173）がタイムアウトして exit 1 になる。近年の学内 Wi-Fi（eduroam 系）は PMF optional が多いが、required も珍しくない。

**推奨**: 既定を `1`（optional）にし、コメントを `0=無効 1=任意 2=必須` に直す。PMF 非対応の古い AP でも 1 なら接続できる（交渉で落ちる）ので、既定 1 が安全側。

### 項目 5: `option network 'wwan'` の束縛（OK）

`option network` の実体は **netifd の L2 リンク束縛**:

`files/lib/netifd/wireless-device.uc:74-82`

```ucode
	for (let net in config.network)
		netifd.interface_handle_link({
			name: net, ifname: dev, vlan: config.network_vlan, link_ext: true, up
		});
```

vif 名の通知は `files-ucode/lib/netifd/wireless/mac80211.sh:245` の `netifd.set_vif(k, v.config.ifname)`（実体は `/usr/lib/netifd/utils.uc` の ubus notify）。

**`wwan` を disabled にすると vif が起動しない**:

`wireless-device.uc:328-350`（`wdev_update_disabled_vifs`）で、束縛先ネットワークが disabled なら vif を `disabled[name] = true` にする。→ setup.sh L107-109（`network.wwan` を `proto=dhcp` / `disabled='0'`）は**必須で正しい**。

制約（該当しないが記録）: `supplicant.uc:276-281`

```ucode
	if (interface.bridge && (mode == 'adhoc' ||
	    (mode == 'sta' && !wds && !multi_ap))) {
		netifd.setup_failed('BRIDGE_NOT_ALLOWED');
```

→ `network.wwan` を `type 'bridge'` にすると STA は起動できない。現状は `proto dhcp`（bridge でない）ので問題なし。

### 項目 6: `band` / `channel` / `country` / `disabled`（OK・注意付き）

schema `files-ucode/usr/share/schema/wireless.wifi-device.json`:

```json
"band":    { "type": "string", "enum": ["2g", "5g", "6g", "60g"] },
"channel": { "description": "Specifies the wireless channel. “auto” defaults to the lowest available channel, or utilizes the ACS algorithm ...", "type": "string" },
"country": { "type": "alias", "default": "country_code" },
"country_code": { "description": "Specifies the two-letter country code (e.g. EN or DE), affects the available channels and transmission powers", "type": "string" },
"disabled": { "description": "When set to 1, wireless network is disabled", "type": "boolean", "default": false }
```

- **`country` は alias**。`validate.uc:83-104` が実体変換を行う:

```ucode
96	for (let k, v in dict) {
97		if (schema[k]?.type != 'alias')
98			continue;
102		dict[schema[k].default] = v;
103		delete dict[k];
```

  → `option country 'JP'` は `country_code='JP'` として扱われる。**書き方は正しい**。
- `channel 'auto'` は ucode 側で `0` に落として周波数計算（`files-ucode/lib/netifd/wireless/mac80211.sh:68-71`）。AP 側で `channel 6` を明示するのは問題なし。
- 実際の規制ドメイン適用は 2 経路:
  - STA ラジオ: `supplicant.uc:283` `interface.config.country = data.config.country_code;` → `:291` の `append_vars(interface.config, ['country', ...])` で wpa_supplicant.conf の**グローバル** `country=JP` になる（`common.uc:70-73` の `append()` はグローバル領域へ）
  - AP ラジオ: `hostapd.uc:71-84` `device_country_code()` が `ubus call network.wireless status` の `radio.config.country` を読み hostapd に `country_code` を渡す
- **未確認（要注意）**: ucode の `setup_phy()` は `config.country` を見て `iw reg set` する（`mac80211.sh:73-76`）が、その直前に `validate('device', config)` が走って `country` を `country_code` に改名済み（同 `:208-209`）。したがって **この `iw reg set` は実行されない（デッドコード）** と読める。実害は上記 2 経路がカバーするため無いと判断したが、実機で `iw reg get` の国コードが JP になるかは要確認。
- **5GHz に国コードが要る根拠**（OpenWrt 自身の扱い）: `files/lib/wifi/mac80211.uc:88-94` で国コード未設定なら 2g 以外の既定 AP を作らず（`defaults = null`）、`:115` で `disabled='${defaults ? 0 : 1}'` を書く。つまり「国コード未設定 → 5GHz は disabled で生成」。
- `band` は `wifi config` が必ず書く（`mac80211.uc:102`）ので、setup.sh L74/L80 の `.band=` 検出・`band_radio` は成立する。

### 項目 7: AP+STA 同時（OK）

- 別ラジオ（AP=2g / STA=5g）なら **wds も multi_ap も不要**。`supplicant.uc:305` は `'4addr': !!interface.config.wds`（wds のときだけ 4addr）、`multi_ap` の既定は 0（同 `:75`）。
- 同一ラジオのときだけ影響がある: `files-ucode/lib/netifd/wireless/mac80211.sh:260` で STA を持つラジオは `data.ap_start_disabled = true` になり、`ap.uc:540` が `config.start_disabled = data.ap_start_disabled` として hostapd.conf に渡す。→ **同じラジオでは AP は STA 接続後にしか上がらない**（＝学校 Wi-Fi に繋がらないと自前 SSID も出ない）。
- setup.sh L91-93 は同一ラジオを警告するだけで止めない。既定（2g/5g 別）なら問題なし。

### 項目 8: firewall4 で wan ゾーンに `wwan` を足す（OK）

`firewall4/root/usr/share/ucode/fw4.uc:1991-2019`（`parse_zone`）:

```ucode
		name: [ "identifier", null, REQUIRED ],
		network: [ "device", null, PARSE_LIST ],
		device: [ "device", null, PARSE_LIST ],
		masq: [ "bool" ],
```

`zone.network` の値は netifd の**インターフェース名**として ubus の状態と突き合わせられる:

- `fw4.uc:603` `ifaces = bus.call("network.interface", "dump");`
- `fw4.uc:621` `device: ifc.l3_device ?? ifc.device,`
- `fw4.uc:676` `networks[ifc.interface] = net;`
- `fw4.uc:2053-2065` で zone の device を解決
- masq の実体は `root/usr/share/firewall4/templates/zone-masq.uc` の `masquerade` 文

→ **`list network 'wwan'`（netifd 名）を wan ゾーンに足すのは fw4 の設計どおりで正しい**。setup.sh L143-148 の方針は妥当。

補足:

1. wan ゾーンは既定で `masq 1`（`firewall4/root/etc/config/firewall:17-23`、同内容が `package/network/config/firewall/files/firewall.config:17-23`）。L145 の `masq='1'` は**冗長だが無害**（冪等性のため残してよい）。
2. **ゾーン特定の脆さ**: L143 の sed は `firewall.@zone[1].name='wan'` にも一致する（`@zone[1]` にドットが無いため）ので実質 `@zone[1]` になる。既定 config では wan が `@zone[1]` で正しいが、**匿名セクションの並び順に依存**する。名前付きセクション（`config zone 'wan'`）に移行している構成では `firewall.wan.name` に一致して安定する。フォールバック `@zone[1]` は「wan が 2 番目」前提なので、より安全にするなら `uci show firewall | grep -c ...` ではなく `network` リストに `wan` を含むゾーンを探す方が堅い。
3. **順序は問題ない**: `wifi reload`（L156）は `ubus call network reload`（`wifi` スクリプト `:52-54`）で、netifd の `config_init_all()` が `netifd_ucode_config_load()` を呼ぶ（netifd `config.c:814, 825`）ため、追加した wwan vif も反映される。firewall restart 時点で wwan が未 up でも、`firewall4/root/etc/hotplug.d/iface/20-firewall` が `ifup`/`ifupdate` で `fw4 -q reload` するので NAT は後追いで有効になる。

### 項目 9（追加）: wpad が EAP 対応版か — **最重要の前提**

`target/linux/ramips/mt7621/target.mk:13`

```make
DEFAULT_PACKAGES += wpad-basic-mbedtls uboot-envtools kmod-crypto-hw-eip93
```

`package/network/services/hostapd/files/wpa_supplicant-basic.config`（basic 系が使う。`Makefile:249-251` で `VARIANT:=basic-mbedtls` + `DEFAULT_VARIANT:=1`）:

```
 94	#CONFIG_IEEE8021X_EAPOL=y
100	#CONFIG_EAP_MSCHAPV2=y
103	#CONFIG_EAP_TLS=y
106	#CONFIG_EAP_PEAP=y
109	#CONFIG_EAP_TTLS=y
```

`files/wpa_supplicant-full.config` は同じ行が `=y`（`:94, 100, 103, 106, 109`）。

→ **`wpad-basic-mbedtls` の wpa_supplicant は EAP を一切サポートしない**。この場合 `option encryption 'wpa2'` + `eap=PEAP` を書いても wpa_supplicant が `EAP: unsupported method` で失敗し、学内 Wi-Fi に繋がらない。項目 1〜3 の正しさは無意味になる。

**必須の確認**:

```sh
opkg list-installed | grep -i wpad
# 期待: wpad-mbedtls / wpad-openssl / wpad-wolfssl（full 系）
# NG  : wpad-basic-mbedtls / wpad-basic-wolfssl / wpad-basic-openssl
```

NG の場合はイメージを作り直す（`CONFIG_PACKAGE_wpad-mbedtls=y`、`wpad-basic-mbedtls` は自動的に外れる）。AP 側も同じバイナリで PSK は普通に動くので、置き換えで両方成立する。

（注意: `wpad-basic-mbedtls` は「WPA-PSK, 11r, 11w」のみ。description も `Makefile:245-247` にそう書かれている。）

---

## 3. 未確認事項

| 項目 | 状態 |
|---|---|
| ucode の `iw reg set`（`mac80211.sh:73-76`）が実際に走るか | コード上は `validate()` の後なので**走らない**と読める。`iw reg get` を実機で確認する必要あり（wpa_supplicant / hostapd 経由で JP になるはず） |
| 学内 AP の PMF 要求有無 | AP 側の設定次第。`iw dev wlan0 scan` の RSN capabilities で確認可能 |
| 学校の RADIUS 証明書の発行 CA | 私設 CA なら `ca_cert` 明示が必要 |
| `wpad` の実種別 | ビルド済みイメージで `opkg list-installed` により要確認（項目 9） |
| 同じラジオで AP+STA にした場合の実挙動 | `start_disabled=1` の hostapd が STA 接続後に立ち上がる、というコード上の推論のみ。既定構成（別ラジオ）では不要 |

---

## 4. setup.sh への差分案（提案のみ・ファイルは未編集）

### 4-1. PMF の既定値とコメント（L30）

```diff
-PMF="${PMF:-0}"                     # 802.11w: 0=任意 1=必須 2=必須(強制)
+PMF="${PMF:-1}"                     # 802.11w: 0=無効 1=任意(optional) 2=必須(required)
```

理由: `ieee80211w` の 0 は「任意」ではなく**無効**（`wireless.wifi-iface.json` の enum 説明）。PMF 必須の学内 AP では 0 だと assoc 拒否。1 なら PMF 非対応 AP とも PMF 必須 AP とも交渉できる。

### 4-2. wpad のプリフライト（「--- 0) 前提」ブロック、L63-67 付近に追加）

```diff
 # --- 0) 前提 -------------------------------------------------
 command -v "$UCI" >/dev/null 2>&1 || die "uci が見つかりません（OpenWrt 上で実行してください）"
 command -v "$WIFI" >/dev/null 2>&1 || warn "wifi コマンドが見つかりません"
+
+# WPA2-Enterprise には EAP 対応の wpad（full 系）が必須
+if command -v opkg >/dev/null 2>&1; then
+	WPAD=$(opkg list-installed 2>/dev/null | sed -n 's/^\(wpad[^ ]*\) .*/\1/p' | head -n1)
+	case "$WPAD" in
+	wpad-basic*|wpad-mini*|wpad)
+		die "EAP 非対応の $WPAD が入っています。wpad-mbedtls 等の full 版が必要です（wpa_supplicant-basic.config で CONFIG_EAP_* が無効）"
+		;;
+	'')	warn "wpad パッケージが見つかりません。EAP が使えない可能性があります" ;;
+	esac
+	log "wpad=$WPAD"
+fi
+
+# ca_cert_usesystem=1 の前提ファイル
+if [ "$CA_USESYSTEM" = "1" ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
+	warn "/etc/ssl/certs/ca-certificates.crt がありません（ca-bundle 未導入）。サーバ証明書は検証されません"
+fi
```

理由: 項目 9 が NG だと以降の設定が全て無効。CA ファイルも無言でスキップされる仕様（`supplicant.uc:151-152`）なので、事前に気づけるようにする。

### 4-3. 私設 CA 用の口（L29 付近と L122 付近）

```diff
 CA_USESYSTEM="${CA_USESYSTEM:-1}"   # 1=システムCAで証明書検証 / 0=検証しない
+CA_CERT="${CA_CERT:-}"              # 学内私設CAの PEM パス（指定時はこちらを優先）
```

```diff
 u set wireless.sta_wan.ca_cert_usesystem="$CA_USESYSTEM"
+if [ -n "$CA_CERT" ]; then u set wireless.sta_wan.ca_cert="$CA_CERT"; else u delete wireless.sta_wan.ca_cert 2>/dev/null || true; fi
```

理由: `ca_cert` を直接渡す経路が現状無い。私設 CA の学校では ca-bundle 検証が失敗する（`supplicant.uc:151-152` は `ca_cert_usesystem` が真なら**必ず** ca-bundle を指すため、併用できない点に注意 — 両方指定すると `ca_cert` が上書きされる。順序は `ca_cert_usesystem` を 0 にして `ca_cert` を渡すのが確実）。

→ より安全な形:

```diff
-if [ -n "$CA_CERT" ]; then u set wireless.sta_wan.ca_cert="$CA_CERT"; else u delete wireless.sta_wan.ca_cert 2>/dev/null || true; fi
+if [ -n "$CA_CERT" ]; then
+	u set wireless.sta_wan.ca_cert_usesystem='0'
+	u set wireless.sta_wan.ca_cert="$CA_CERT"
+else
+	u set wireless.sta_wan.ca_cert_usesystem="$CA_USESYSTEM"
+	u delete wireless.sta_wan.ca_cert 2>/dev/null || true
+fi
```

### 4-4. STA ラジオ上の既定 AP を止める（L99-103 付近に追加）

```diff
 u set wireless.$DEV_AP.channel="$AP_CHANNEL"
+
+# STA 側ラジオに既定で生えている AP を止める（同一ラジオ AP+STA の回避）
+for s in $(u show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
+	[ "$s" = "sta_wan" ] && continue
+	[ "$s" = "$AP_IF" ] && continue
+	[ "$(u get wireless.$s.device 2>/dev/null)" = "$DEV_STA" ] || continue
+	[ "$(u get wireless.$s.mode 2>/dev/null)" = "ap" ] || continue
+	u set wireless.$s.disabled='1'
+	log "STA ラジオの既定 AP ($s) を無効化"
+done
```

理由: `wifi config` は 5GHz 側にも `default_radio1`（AP, network=lan, disabled=0）を生成する。STA と同じラジオに AP が残ると `ap_start_disabled`（`mac80211.sh:260` → `ap.uc:540`）で hostapd が STA 接続後まで上がらず、切り分けが難しくなる。なお `$AP_IF` は L128-131 で確定するので、このブロックは L138（`log "AP側 iface=$AP_IF"`）の**後**に置くのが安全。

### 4-5. firewall ゾーン特定の堅牢化（L143-145）

```diff
-WAN_ZONE=$(u show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -n1)
-[ -n "$WAN_ZONE" ] || WAN_ZONE='@zone[1]'
+# name='wan' が無ければ「network に wan を含むゾーン」を探す（匿名セクション順序に依存しない）
+WAN_ZONE=$(u show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -n1)
+[ -n "$WAN_ZONE" ] || WAN_ZONE=$(u show firewall 2>/dev/null \
+	| sed -n "s/^firewall\.\([^.]*\)\.network='\(.*\)'\$/\1 \2/p" \
+	| awk '$2 ~ /(^| )wan( |$)/ {print $1; exit}')
+[ -n "$WAN_ZONE" ] || die "wan ゾーンが見つかりません（/etc/config/firewall を確認）"
```

理由: 現行のフォールバック `@zone[1]` は匿名セクションの並び順前提。fw4 のゾーンは `name` より `network` の内容で意味が決まる（`fw4.uc:2053-2065`）ため、`network` に `wan` を含むゾーンを探す方が意図に合う。

### 4-6. 変更不要（確認済みで正しい）

- L114 `encryption='wpa2'`（STA）→ EAP になる（項目 1）
- L116-121 `eap_type` / `identity` / `password` / `auth` / `anonymous_identity`（項目 2）
- L105-109 `network.wwan`（`proto=dhcp`, `disabled=0`）（項目 5）
- L98-101 `country='JP'` / `disabled='0'`（項目 6）
- L143-148 の `add_list network wwan` と `masq`（項目 8）
- L152-156 の `commit` → `wifi reload` → `firewall restart` の順序（項目 8-3）

---

## 5. 実機での確認手順（フラッシュ後）

```sh
# 1) wpad 種別（最重要）
opkg list-installed | grep -i wpad

# 2) EAP 機能がバイナリに入っているか
wpa_supplicant -v            # バージョンだけでは分からないので下で確認
strings /usr/sbin/wpa_supplicant | grep -i mschapv2   # 何も出なければ EAP 非対応

# 3) 設定反映後
wifi status
cat /var/run/wpa-supplicant-*.conf        # eap=PEAP / phase2="auth=MSCHAPV2" / country=JP を確認
iw reg get                                # country JP になっているか
ubus call network.interface.wwan status   # up:true と IP

# 4) 失敗時のログ
logread | grep -iE 'eap|8021x|deauth|wpa_supplicant|CTRL-EVENT'
iw dev wlan0 scan | grep -A6 "$SSID"      # RSN capabilities で PMF required か確認
```
