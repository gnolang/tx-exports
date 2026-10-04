// v0 - Unaudited: This is an initial version that has not yet been formally audited.
// Use in production at your own risk.
//
// Package game is the on-chain part of gnofly, a multiplayer plane game. It is
// the source of truth for everything an admin can tune: the game parameters,
// the roles and the treasury. It also keeps what the referee attests and what
// has lasting value: the kills, on the kill leaderboard. Skins and planes are
// tokens of their own realms, gnofly/nfts/skins and gnofly/nfts/planes, which
// ask this one who the admins are and where the treasury is.
//
// Three kinds of callers write to it:
//
//   - the owner and the admins tune the game (SetParam, ...). Every such
//     write bumps Version, which is how the game server knows it has to read
//     StateJSON again;
//   - referees, the game servers, record kills (SubmitKills).
//
// Challenge runs never reach the chain: the game server defines the
// challenges, scores the runs and keeps the session boards.
//
// Reads are plain functions meant for vm/qeval. The ones ending in JSON
// return a single string holding a JSON document. Render exposes the same
// data as markdown for gnoweb.
package game
