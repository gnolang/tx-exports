package arena

import (
	"chain/runtime"
	"strconv"
	"time"
)

// guard binds the session that signed the transaction to match id, held in m, saving the
// caller's record only when its locks change.
func guard(fromUser bool, caller address, m record, id int) {
	session, expires, ok := signingSession(fromUser)
	if !ok {
		return
	}
	if caller != m.challenger && caller != m.acceptor {
		panic("not a player")
	}
	p := loadPlayer(caller)
	if p.lock(session, expires, id, false, time.Now().Unix()) {
		savePlayer(caller, p)
	}
}

// join adds match id to the caller's record and binds the session that signed the
// transaction to it, refused when that session is bound to a match already.
func join(fromUser bool, caller address, id int) {
	p := loadPlayer(caller)
	if session, expires, ok := signingSession(fromUser); ok {
		p.lock(session, expires, id, true, time.Now().Unix())
	}
	p.add(id)
	savePlayer(caller, p)
}

// signingSession returns the signing session key and its expiry when fromUser: a session
// signs the whole transaction, so a call through another realm is left unchecked.
func signingSession(fromUser bool) (address, int64, bool) {
	if !fromUser {
		return "", 0, false
	}
	session, expires, _, ok := runtime.GetSessionInfo()
	return session, expires, ok
}

// lock binds session to match id in p's locks, panicking when it is refused, and reports
// whether the locks changed.
func (p *playerRecord) lock(session address, expires int64, id int, opening bool, now int64) bool {
	locks, changed, refusal := lockSession(p.locks, session, expires, id, opening, now)
	if refusal != "" {
		panic(refusal)
	}
	p.locks = locks
	return changed
}

// lockSession binds session to match id, refused when bound to another, or any when opening.
// It drops expired locks and any lock its key holds under another expiry (Unix seconds, 0 never).
func lockSession(locks []sessionLock, session address, expires int64, id int, opening bool, now int64) (kept []sessionLock, changed bool, refusal string) {
	for _, l := range locks {
		expired := l.expires != 0 && l.expires <= now
		stale := l.session == session && l.expires != expires
		if !expired && !stale {
			kept = append(kept, l)
		}
	}
	changed = len(kept) != len(locks)
	for _, l := range kept {
		if l.session != session {
			continue
		}
		if opening || l.id != id {
			return kept, changed, "session locked to match " + strconv.Itoa(l.id)
		}
		return kept, changed, ""
	}
	return append(kept, sessionLock{session: session, id: id, expires: expires}), true, ""
}
