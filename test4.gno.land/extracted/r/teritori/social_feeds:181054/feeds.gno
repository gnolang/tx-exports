package social_feeds

import (
	"regexp"

	"gno.land/p/demo/avl"
)

//----------------------------------------
// Realm (package) state

var (
	gFeeds       avl.Tree // id -> *Feed
	gFeedsCtr    int      // increments Feed.id
	gFeedsByName avl.Tree // name -> *Feed
)

//----------------------------------------
// Constants

var reName = regexp.MustCompile(`^[a-z]+[_a-z0-9]{2,29}$`)
