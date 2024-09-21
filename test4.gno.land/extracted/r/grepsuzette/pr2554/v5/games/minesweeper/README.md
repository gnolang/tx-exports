# Underwater Minesweeper

The goal of the game is to **uncover all squares that are not mines**.

Numbers indicate how many adjacent mines are to that tile.

Note: In this version, you can't flag squares, you will have to use your memory.

The little animals 🐠, 🦐, 🦈, 🐳 are protagonists from the ocean but play no part.

## Context

This demo is part of a series of mini-games for GNO, and may or may not be used for Games of Realm.

- GNO is interpreted by the validators on the gno.land chain
- no JS
- no wallet
- client renders Markdown with HTML and CSS

### Developer opinion: bring querystring!

Since no `<form method=GET>` can be used at the moment, because
only realm path is read, not the querystring, 

- each button has to be a `<a>` tag (we put some make up using CSS)...
- ...And the state of the game *has* to be repeated for each tile (each `<a>` contains a state of the game). 
    - If querystring was enabled on gnoweb, with `<form method=GET>` we could just have a **single** `<input type=hidden name=state value=xxxxxxxxxxxxx>`.

- Not only that:
  - ** `<form>` could help introduce micro transitory state** on a webpage, without JS:
  - you could use radio buttons or `<select>` menu that you style. 
  - imagine a **collective pixel-art** wall,
  - you could to choose the color of a pixel you want to paint, 
  - then paint it on the pixel-art wall.
  - as soon as you would click a pixel, it sends you to the realms helper page. 


