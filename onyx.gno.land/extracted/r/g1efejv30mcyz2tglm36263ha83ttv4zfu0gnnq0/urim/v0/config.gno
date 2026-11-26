package urim

// Deploy-time settings. scripts/set-namespace.sh rewrites both before an
// addpkg to a real network, so the realm links to the right web app.
const (
	// AppOrigin is the web app the gnoweb buttons open.
	AppOrigin = "https://urim-mu.vercel.app"
	// realmLink is this realm's gnoweb path.
	realmLink = "/r/g1efejv30mcyz2tglm36263ha83ttv4zfu0gnnq0/urim/v0"
)
