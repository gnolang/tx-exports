# Settlers NTF

Package that draws the Settlers, small pixel-art gnomes, as an SVG.

Given the same traits, it always draws the same image, so it's safe and cheap for any
realm to import and call directly.

Code also lives in [jeronimoalbi/gnoland-settlers](https://github.com/jeronimoalbi/gnoland-settlers).

## From a seed

```go
traits := nft.NewTraits("some-seed-string")
svg := nft.RenderSVG(traits, nft.Options{Size: 512})
```

The traits (skin, hat, beard, clothes, glasses, background, and so on) are all worked
out deterministically from the seed, so the same seed always gives the same gnome.

## From packed traits

Traits are usually stored packed into a single `uint32`:

```go
packed := nft.Pack(traits)
traits, err := nft.FromPacked(packed)
svg := nft.RenderSVG(traits, nft.Options{})
```

`Options` also takes `NoBackground` (a transparent image) and `BackgroundColor`
(a custom one). `RenderDataURI` gives the same image as a `data:image/svg+xml;...` URI,
ready to use as an `<img>` source.

## License

The art itself is dedicated to the public domain under CC0 1.0 Universal; see `Credits`.
