package skins

// catalog is the skin catalog at deploy, one design per line, sorted by id:
//
//	id|name|model|pilot|body|wing|accent|price
//
// The rules are those of SetSkin (see validate.gno); the tests check every
// line. The website reads this file too, at build, to serve the metadata of
// each design at https://gnofly.xyz/nft/skins/<id>.json: a design added later
// with SetSkin needs a line here as well for its JSON to exist.
//
// Classic, the look every pilot flies by default, is not here: it is free and
// drawn by the client, not a token.
const catalog = `baron|Red Baron|biplane|none|#c1121f|#780000|#fdf0d5|7000000
gnome|Garden Gnome|prop|none|#2a9d8f|#e9c46a|#264653|77000000
goldie|Golden Goose|jet|none|#ffd60a|#ffc300|#000814|7777000000
stealth|Night Shift|jet|none|#22223b|#4a4e69|#f72585|777000000`
