// Realm: Watchtower — an on-chain status page for Gno.land.
//
// Service owners register a service, send heartbeats, and report incidents.
// Anyone can read the public status board through Render().
//
// Deploy path (planned): gno.land/r/g1vkwmdxutueeax9ys820gsv6k9qu93ftzet0t7f/watchtower
//
// API notes (verified against gnolang/gno v1.8.0, Fase 0):
//   - The old `std` package (std.Address, std.GetOrigCaller) no longer
//     exists. Addresses use the builtin `address` type.
//   - Exported state-mutating functions take a leading `cur realm`
//     (crossing) parameter; the caller is `cur.Previous().Address()`.
//   - time.Now() is injected by the VM (block time), so it is safe to
//     use as the realm clock.
package watchtower

import (
	"strings"
	"time"

	"gno.land/p/g1vkwmdxutueeax9ys820gsv6k9qu93ftzet0t7f/watchtower"
)

// Incident is a single reported outage / note on a service.
type Incident struct {
	ID       int
	Title    string
	Detail   string
	OpenedAt int64 // unix seconds
	ClosedAt int64 // 0 = still open
	Reporter address
}

// Service is one monitored service on the board.
type Service struct {
	Name           string // unique slug, e.g. "my-realm"
	RealmPath      string // e.g. "gno.land/r/myproject"
	Owner          address
	IntervalSec    int64 // expected heartbeat interval
	LastBeatUnix   int64
	Manual         string // "", "maintenance", "down"
	Incidents      []Incident
	nextIncidentID int
}

var (
	services map[string]*Service
	order    []string // registration order, for stable Render output
)

// --- writes ---------------------------------------------------------------

// RegisterService adds a service to the board. Caller becomes its owner.
func RegisterService(cur realm, name string, realmPath string, intervalSec int64) string {
	caller := cur.Previous().Address()
	if name == "" {
		panic("watchtower: name required")
	}
	if _, exists := services[name]; exists {
		panic("watchtower: service already registered: " + name)
	}
	if intervalSec <= 0 {
		intervalSec = 300
	}
	if services == nil {
		services = make(map[string]*Service)
	}
	services[name] = &Service{
		Name:           name,
		RealmPath:      realmPath,
		Owner:          caller,
		IntervalSec:    intervalSec,
		nextIncidentID: 1,
	}
	order = append(order, name)
	return "registered: " + name
}

// Heartbeat marks a service as alive now. Owner only.
func Heartbeat(cur realm, name string) string {
	s := mustOwn(cur, name)
	s.LastBeatUnix = nowUnix()
	return "ok: " + name
}

// ReportIncident opens an incident on a service. Owner only.
func ReportIncident(cur realm, name string, title string, detail string) string {
	s := mustOwn(cur, name)
	id := s.nextIncidentID
	s.nextIncidentID++
	s.Incidents = append(s.Incidents, Incident{
		ID:       id,
		Title:    title,
		Detail:   detail,
		OpenedAt: nowUnix(),
		Reporter: cur.Previous().Address(),
	})
	return "incident opened"
}

// ResolveIncident closes an open incident. Owner only.
func ResolveIncident(cur realm, name string, id int) string {
	s := mustOwn(cur, name)
	for i := range s.Incidents {
		if s.Incidents[i].ID == id && s.Incidents[i].ClosedAt == 0 {
			s.Incidents[i].ClosedAt = nowUnix()
			return "incident resolved"
		}
	}
	panic("watchtower: open incident not found")
}

// SetMaintenance toggles the manual override: "maintenance", "down" or "".
func SetMaintenance(cur realm, name string, manual string) string {
	s := mustOwn(cur, name)
	switch manual {
	case "", watchtower.ManualMaintenance, watchtower.ManualDown:
		s.Manual = manual
	default:
		panic("watchtower: invalid manual status: " + manual)
	}
	return "manual status set: " + name
}

// --- reads ----------------------------------------------------------------

// GetStatus returns the computed status of one service.
func GetStatus(name string) string {
	s, ok := services[name]
	if !ok {
		return watchtower.StatusUnknown
	}
	return watchtower.ComputeStatus(s.LastBeatUnix, s.IntervalSec, s.Manual, time.Now())
}

// Render draws the public status board.
//
//	"" or "/"        -> all services
//	"/<service>"     -> one service + its incidents
func Render(path string) string {
	var b strings.Builder
	b.WriteString("# Watchtower — Gno.land Status Board\n\n")
	slug := strings.Trim(path, "/")
	if slug != "" {
		s, ok := services[slug]
		if !ok {
			return "# Watchtower\n\nUnknown service: " + slug + "\n"
		}
		writeService(&b, s, true)
		return b.String()
	}
	if len(order) == 0 {
		b.WriteString("No services registered yet.\n")
		return b.String()
	}
	for _, name := range order {
		writeService(&b, services[name], false)
	}
	return b.String()
}

func writeService(b *strings.Builder, s *Service, detail bool) {
	now := time.Now()
	status := watchtower.ComputeStatus(s.LastBeatUnix, s.IntervalSec, s.Manual, now)
	age := "-"
	if s.LastBeatUnix > 0 {
		age = watchtower.FormatAge(now.Unix() - s.LastBeatUnix)
	}
	b.WriteString("## " + s.Name + " " + watchtower.StatusMark(status) + "\n\n")
	b.WriteString("- Realm: " + s.RealmPath + "\n")
	b.WriteString("- Status: " + status + "\n")
	b.WriteString("- Last heartbeat: " + age + " ago\n")
	open := 0
	for _, inc := range s.Incidents {
		if inc.ClosedAt == 0 {
			open++
		}
	}
	b.WriteString("- Open incidents: " + itoaSmall(open) + "\n\n")
	if detail {
		for _, inc := range s.Incidents {
			state := "open"
			if inc.ClosedAt != 0 {
				state = "resolved"
			}
			b.WriteString("- Incident #" + itoaSmall(inc.ID) + " (" + state + "): " + inc.Title + " — " + inc.Detail + "\n")
		}
		b.WriteString("\n")
	}
}

// --- helpers --------------------------------------------------------------

func mustOwn(cur realm, name string) *Service {
	s, ok := services[name]
	if !ok {
		panic("watchtower: unknown service: " + name)
	}
	if caller := cur.Previous().Address(); caller != s.Owner {
		panic("watchtower: not the service owner")
	}
	return s
}

func nowUnix() int64 {
	// time.Now() is VM-injected (block time) in Gno — deterministic on-chain.
	return time.Now().Unix()
}

func itoaSmall(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [12]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
