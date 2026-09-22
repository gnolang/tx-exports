# canvas

Pure package `gno.land/p/g1v7s3j506wqul2zwt90awgjphpx4ztwga0926f7/canvas/v0`: a fixed-size grid of palette
indexes with lazy per-row allocation, plus the `x,y,color;...` batch codec.

Used by the realm `gno.land/r/g1v7s3j506wqul2zwt90awgjphpx4ztwga0926f7/gnodraw/v0`, which adds pricing and
access control. The package itself holds no chain state and has no chain
imports, so it is fully covered by plain unit tests (`gno test .`).

- `New(width, height)`: empty canvas, sides between 1 and 10000.
- `Set(Pixel)`, `Get(x, y)`, `Check(Pixel)`: paint, read, validate.
- `Rows(from, to)`: rows as one hex digit per pixel, no separators.
- `ParsePixels`, `Encode`, `ParseColor`: the batch format.
- `Palette`: 16 CSS colors, index 0 being "never painted".
