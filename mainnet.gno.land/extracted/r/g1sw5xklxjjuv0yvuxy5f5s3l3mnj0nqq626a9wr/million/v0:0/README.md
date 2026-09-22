# million

Realm `gno.land/r/g1sw5xklxjjuv0yvuxy5f5s3l3mnj0nqq626a9wr/million/v0`: a 1250 x 800 (one million pixels, 16:10) pay-per-pixel canvas
built on `gno.land/p/g1sw5xklxjjuv0yvuxy5f5s3l3mnj0nqq626a9wr/canvas/v0`.

Paint from the CLI:

```sh
gnokey maketx call -pkgpath gno.land/r/g1sw5xklxjjuv0yvuxy5f5s3l3mnj0nqq626a9wr/million/v0 -func PaintBatch \
  -args "10,10,6;11,10,6" -send 100000ugnot \
  -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast -chainid dev -remote 127.0.0.1:26657 <key>
```

The amount sent must equal `Price()` times the number of pixels, and the
call must come directly from a user transaction. Payments are forwarded to
the admin wallet (`Owner()`) as they arrive; the admin paints for free and
can `SetPrice`, `Withdraw` and `TransferOwnership`. Read functions used by clients:
`GetWidth`, `GetHeight`, `Price`, `Palette`, `MaxBatchSize`, `Painted`,
`Pixel(x, y)`, `Rows(from, to)`, `Version()`, `DirtyRows(since)`.

`Version()` counts successful paint calls and `DirtyRows(since)` lists the
rows touched after that version, so clients fetch only what changed.
