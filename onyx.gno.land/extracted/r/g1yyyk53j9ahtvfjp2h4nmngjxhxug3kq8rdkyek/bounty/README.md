# Bounty Board — Gnome Tavern Hackathon | Gno.land

Papan bounty on-chain: siapa pun bisa memposting bounty, alamat lain
mengambilnya, dan hanya pembuat bounty yang bisa menandainya selesai.

- Realm: `gno.land/r/g1yyyk53j9ahtvfjp2h4nmngjxhxug3kq8rdkyek/bounty`
- Toolchain: gno v1.8.0, `export GNOROOT=$HOME/gno`
- Status: teruji lokal + gnodev, **siap deploy** (saldo wallet 300 GNOT
  di Onyx testnet, terverifikasi via ABCI query 26 Nov 2026). Belum di-deploy.

## Fungsi

| Fungsi | Keterangan |
|---|---|
| `PostBounty(title, description, reward) (int, error)` | Buat bounty baru (status `open`), kembalikan id-nya. Judul dan reward wajib diisi. |
| `ClaimBounty(id) error` | Ambil bounty yang masih `open`. Pembuat tidak bisa mengklaim bounty sendiri; satu bounty hanya bisa diklaim sekali. |
| `CompleteBounty(id) error` | Tandai bounty yang sudah diklaim sebagai `done`. Hanya pembuat bounty, dan hanya setelah ada yang mengklaim. |
| `BountyCount() int` | Jumlah bounty yang pernah diposting. |
| `GetBounty(id) (string, error)` | Ringkasan satu bounty (judul, reward, pembuat, pengklaim, status). |
| `ListBounties() string` | Ringkasan satu baris per bounty. |
| `Render(path string) string` | Tampilkan papan sebagai Markdown (judul/deskripsi disanitasi). |

Reward bersifat informasional (mis. `"100ugnot"`); versi realm ini tidak
meng-escrow token — catatan on-chain melacak siapa yang mengklaim dan
apakah pembuat sudah menandainya selesai.

## Cara test

```sh
export GNOROOT=$HOME/gno
export PATH=$HOME/.gno/bin:$PATH
gno fmt ./...   # format
gno lint ./...  # lint
gno test -v .   # 9 test, semua harus PASS
```

Test mencakup: posting bounty, klaim valid, klaim ganda ditolak, klaim
bounty sendiri ditolak, complete oleh non-pembuat ditolak, complete oleh
pembuat berhasil, complete bounty yang belum diklaim ditolak, dan id
tidak valid ditolak.

## Coba lokal (gnodev)

```sh
gnodev local -node-rpc-listener 127.0.0.1:26658 -web-listener 127.0.0.1:8889 .
# buka http://127.0.0.1:8889/r/g1yyyk53j9ahtvfjp2h4nmngjxhxug3kq8rdkyek/bounty
```

Terverifikasi 26 Nov 2026: realm ke-load dan Render jalan di node lokal,
plus urutan transaksi end-to-end (Post → Claim → klaim ganda ditolak
on-chain → Complete oleh non-pembuat ditolak on-chain → Complete oleh
pembuat berhasil, status akhir `done`).

## Deploy ke Onyx testnet

```sh
./deploy.sh   # butuh ../wallet-seed.txt (password keybase dibaca dari sana)
```

Verifikasi setelah deploy:
`https://latest.testnets.gno.land/r/g1yyyk53j9ahtvfjp2h4nmngjxhxug3kq8rdkyek/bounty`

Catatan: klien HTTP Go di `gnokey` gagal TLS lewat egress proxy VM ini;
kalau `-broadcast` gagal, deploy.sh menjelaskan fallback (sign offline,
broadcast JSON via curl).

## Catatan implementasi

- **Tidak ada paket `std` di gno v1.8.0** (paket itu sudah di-split):
  identitas pemanggil diambil dari `cur.Previous().Address()`, tipe alamat
  memakai builtin `address`, error memakai paket stdlib `errors`.
- Judul/deskripsi yang ditulis pengguna disanitasi dengan
  `sanitize.InlineText` (`gno.land/p/nt/markdown/sanitize/v0`) sebelum
  masuk ke output Markdown `Render`, sesuai panduan keamanan Gno.
- Dependensi `gno.land/p/...` (`testutils`, `sanitize`) di-resolve dari
  clone lokal: cache modul di `~/.config/gno/pkg/mod/` diisi manual dari
  `~/gno/examples/` + marker file, karena `gno mod download` gagal TLS
  lewat proxy VM.
- Di `_test.gno`, `testing.SetRealm` dan pemanggilan crossing
  (`fn(cross(cur), ...)`) **harus** ditulis langsung di badan fungsi test —
  kalau dilewatkan helper, `cur.Previous()` tidak lagi mengembalikan
  alamat user yang di-set (dan state global `bounties` harus di-reset
  tiap test karena `gno test` menjalankan semua test dalam satu machine).
