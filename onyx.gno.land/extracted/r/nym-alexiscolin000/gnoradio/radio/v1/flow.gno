package radio

// Main's flow is a pure function of the clock and the stations: between
// listeners' picks, each UTC hour Main simulcasts one genre station, playing
// what it plays (its own picks included) until the next hour. The hour's genre follows an energy line around the
// target of the time of day (UTC dayparts: calm at night, peak in the
// evening): one step below the target in a 3-hour block's first hour, the
// target in its second, one step above in its third, or the nearest genre
// with a live track. Reads compute it and nothing is written, so it never
// runs dry and costs GnoRadio nothing: no Sync, robot or keeper.

// energy orders the genres from calm to intense; neighbours blend well.
var energy = [NumGenres]int{
	3,  // Ambient
	16, // Cinematic & Classical
	15, // Folk & Acoustic
	14, // Jazz & Blues
	8,  // Lo-fi Beats
	10, // R&B & Soul
	19, // Reggae & Dub
	17, // World
	18, // Latin
	20, // Funk & Disco
	13, // Pop
	9,  // Hip-hop & Rap
	11, // Rock & Indie
	2,  // Synthwave
	1,  // Electronica
	5,  // House
	4,  // Techno
	7,  // Dubstep & Trap
	6,  // Drum & Bass
	12, // Metal & Punk
}

// dayparts is the target index in energy for each 3-hour block of the UTC day:
// Jazz, Ambient, Lo-fi, World, Pop, Rock, House, then Drum & Bass at the peak.
var dayparts = [8]int{3, 0, 4, 7, 10, 12, 15, 18}

// hourGenre is the genre Main relays at ts: the daypart's target, one step
// below it in the block's first hour, above it in the last, or the nearest
// genre with a live track (0: none).
func hourGenre(t *tx, ts int64) int {
	h := ts / 3600
	i := dayparts[h%24/3] + int(h%3) - 1
	if i < 0 {
		i = 0
	} else if i >= len(energy) {
		i = len(energy) - 1
	}
	for k := 0; k < 2*len(energy); k++ {
		if j := i + (k+1)/2*(1-2*(k%2)); j >= 0 && j < len(energy) && t.hasLive(energy[j]) {
			return energy[j]
		}
	}
	return 0
}

// HourGenre is the genre Main relays at unix time at (0: none), for pages
// that explain it.
func HourGenre(at int64) int { return hourGenre(rd(), at) }
