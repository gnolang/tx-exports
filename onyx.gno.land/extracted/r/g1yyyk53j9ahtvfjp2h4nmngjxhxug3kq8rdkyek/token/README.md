# Gnome Tavern Tip (TIP) — Token GRC20

Realm token standar Gno untuk Gnome Tavern Hackathon | Gno.land
(deadline submit **18 Des 2026 08:00 WIB**). Proyek ke-2 dari tiga submission
Gnome Tavern (poll di `../realm/`, bounty board di `../bounty/`).

- **Token:** Gnome Tavern Tip, simbol **TIP**, desimal 6
- **Realm:** `gno.land/r/g1yyyk53j9ahtvfjp2h4nmngjxhxug3kq8rdkyek/token`
- **Owner:** wallet hackathon `g1yyyk53j9ahtvfjp2h4nmngjxhxug3kq8rdkyek`
  (satu-satunya yang bisa Mint/Burn)
- **Initial supply:** 1.000.000 TIP (= 10^12 base unit) ke owner saat `init`

Mengikuti pola kanonik `gno.land/r/demo/defi/foo20`: `grc20.NewToken` +
`CallerTeller` + `ownable`-gated Mint/Burn. Token TIDAK didaftarkan ke
`grc20reg` (opsional; menjaga test tetap hermetic tanpa realm registry).

## Fungsi

| Fungsi | Keterangan |
|---|---|
| `TotalSupply() int64` | total TIP yang ada |
| `BalanceOf(owner address) int64` | saldo satu alamat |
| `Allowance(owner, spender address) int64` | allowance spender |
| `Transfer(cur realm, to, amount)` | kirim TIP (caller = pengirim) |
| `Tip(cur realm, to, amount)` | sama dengan Transfer, dinamai untuk use case tipping |
| `Approve(cur realm, spender, amount)` | setujui spender |
| `TransferFrom(cur realm, from, to, amount)` | kirim pakai allowance |
| `Mint(cur realm, to, amount)` | cetak TIP baru — hanya owner |
| `Burn(cur realm, from, amount)` | musnahkan TIP — hanya owner |
| `Render(path string)` | home: info token + saldo viewer; `:balance/<addr>` → saldo |

Render home menampilkan info token + saldo viewer; saldo satu alamat bisa
dilihat di `.../token:balance/<alamat>` (perhatikan `:`, itu sintaks args
gnoweb — path `/balance/...` biasa akan 404).

## Test lokal

```sh
export GNOROOT=$HOME/gno
export PATH="$HOME/.gno/bin:$PATH"
gno fmt ./...
gno lint ./...
gno test -v ./...   # 3 test: TestTokenFlow, TestMintByNonOwnerRejected,
                    # TestTransferExceedsBalanceRejected
gnodev .            # devnet lokal + web UI di http://localhost:8888
```

Catatan environment (ditemukan saat setup, 26 Nov 2026):

- **Tidak ada paket `std` di gno v1.8.0** — `import "std"` gagal
  (`package std is not in std`). Identitas viewer di Render diambil lewat
  `chain/runtime/unsafe`.OriginCaller(), bukan `std.GetOrigCaller()`.
  (Realm `board` lama di `../realm/` masih memakai `std` — itu perlu
  diperbaiki kalau mau dipakai lagi.)
- **Mod cache harus diisi manual**: klien HTTP Go gagal TLS lewat egress
  proxy VM ini, jadi `gno mod download` tidak bisa mengambil
  `gno.land/p/nt/*` dari `rpc.gno.land`. Cache sudah diisi dari checkout
  lokal `~/gno/examples` (10 paket: grc20, ownable, ufmt, testutils,
  uassert + transitif avl, seqid, cford32, urequire, onbloc/diff) ke
  `~/.config/gno/pkg/mod/` beserta marker file-nya. Kalau cache terhapus,
  jalankan ulang skrip pengisi dari parent (atau `gno mod download` dari
  jaringan yang tidak lewat proxy ini).
- **Test berbagi satu realm state** dan jalan berurutan per file (seperti
  foo20): `TestTokenFlow` melacak saldo kumulatif; test penolakan mengambil
  baseline dulu supaya tidak bergantung pada urutan.

## Deploy ke Onyx testnet

```sh
./deploy.sh   # butuh saldo ugnot di wallet (faucet: https://faucet.gno.land)
```

Biaya deploy: gas (floor 1 ugnot / 1000 gas) + storage deposit 100 ugnot
per byte kode/state. Verifikasi setelah deploy di:
`https://latest.testnets.gno.land/r/g1yyyk53j9ahtvfjp2h4nmngjxhxug3kq8rdkyek/token`

Catatan: `gnokey` (klien HTTP Go) gagal TLS lewat egress proxy VM ini —
`deploy.sh` sudah menyiapkan fallback (sign offline + broadcast via curl)
kalau `-broadcast` gagal, sama seperti `../deploy.sh`.
