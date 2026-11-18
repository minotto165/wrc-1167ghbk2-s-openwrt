# 配下の端末を DoH にする（任意）

学校の DNS フィルタを回避するための追加設定。ルーター1台に適用すれば、配下の端末は OS を問わず設定不要になる。

```
端末 → 192.168.1.1:53 (dnsmasq) → 127.0.0.1:5053 (https-dns-proxy) → DoH 443/TCP
```

## パッケージ

24.10.8 は opkg（`apk` は 25.12 以降）。`dnscrypt-proxy2` は 13.1MB あり、16MB フラッシュのこの機種には入らないので `https-dns-proxy`（依存込みで約 850KB）を使う。

```sh
opkg update
opkg install https-dns-proxy
```

## 設定

リゾルバを2本立てる。

```sh
uci set https-dns-proxy.dnscry=https-dns-proxy
uci set https-dns-proxy.dnscry.resolver_url='https://tyo03.dnscry.pt/dns-query'
uci set https-dns-proxy.dnscry.bootstrap_dns='210.130.0.3,210.130.1.3'
uci set https-dns-proxy.dnscry.listen_port='5053'

uci set https-dns-proxy.slowb=https-dns-proxy
uci set https-dns-proxy.slowb.resolver_url='https://dns1.slowb.ro/dns-query'
uci set https-dns-proxy.slowb.bootstrap_dns='210.130.0.3,210.130.1.3'
uci set https-dns-proxy.slowb.listen_port='5054'

uci commit https-dns-proxy
/etc/init.d/https-dns-proxy enable
/etc/init.d/https-dns-proxy restart
```

このパッケージは次を自分で行う。手で触ると壊れるので任せる。

- `dnsmasq` を `noresolv=1` + `server=127.0.0.1#5053` `#5054` に書き換える（`dnsmasq_config_update='*'`）
- `br-lan` からの外向き 53/853 を nftables で横取りする（`force_dns='1'`）。端末が 8.8.8.8 を直書きしていても効く
- iCloud Private Relay と Firefox の canary ドメインを応答して、端末側の自動 DoH を抑止する

`bootstrap_dns` は DoH サーバーのホスト名を引くための平文 DNS。起動時にだけ使う。

## 検証

```sh
nslookup one.one.one.one          # 1.1.1.1 が返る（146.112.61.106 なら未通過）
```

平文 DNS を使っていないかは、外向き 53 を落として確かめる。それでも解決できれば経路は DoH だけ。

```sh
nft add table inet dohtest
nft add chain inet dohtest out '{ type filter hook output priority -10; policy accept; }'
nft add rule inet dohtest out ip daddr != 127.0.0.1 udp dport 53 drop
nft add rule inet dohtest out ip daddr != 127.0.0.1 tcp dport 53 drop
nslookup one.one.one.one
nft delete table inet dohtest
```

横取りが効いているかはカウンタで見る。`redirect` の packets が増えていれば、端末の DNS はルーターに吸われている。

```sh
nft list ruleset | grep -E 'dport (53|853)'
```

DoH の接続先は conntrack で確認できる。

```sh
cat /proc/net/nf_conntrack | grep 'dport=443' | grep -oE 'dst=[0-9.]+' | sort | uniq -c | sort -rn | head
```

## 戻す

```sh
/etc/init.d/https-dns-proxy stop
opkg remove https-dns-proxy
uci set dhcp.@dnsmasq[0].noresolv='0'
uci -q delete dhcp.@dnsmasq[0].server
uci commit dhcp
/etc/init.d/dnsmasq restart
```

## 注意

- `sysupgrade` で消える。パッケージは overlay に載るので、ファームを上げ直したら入れ直す。`/etc/config/https-dns-proxy` は残る
- DoH で消えるのは DNS フィルタだけ。IP 直ブロック（1.1.1.1 / 8.8.8.8）と ICMP 遮断は残るので、`ping` は通らないままになる
- 853 は `reject` される。DoT を使おうとした端末は平文に落ちて、それも redirect される
