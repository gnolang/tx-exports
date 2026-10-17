// Package trigger holds the Trigger struct that gnotif registries accept. A
// struct declared in a realm cannot be built by another realm, so it lives in
// a pure package.
package trigger

// Trigger holds one trigger's fields. Filter is comma-separated key=value
// pairs; Title, Body and Link are templates where {key} stands for the value
// of the event's attribute key.
type Trigger struct {
	Event, Filter, Param, Title, Body, Link string
}
