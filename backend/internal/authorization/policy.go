// Package authorization defines the shared application authorization contract.
// Transport credentials and UI flags are deliberately absent from this package.
package authorization

import (
	"context"
	"errors"
	"slices"
)

var ErrDenied = errors.New("permission denied")

type Grants struct {
	ExternalScreenIDs []string `json:"external_screen_ids"`
	Roles             []string `json:"roles"`
	AllStations       bool     `json:"all_stations"`
	StationIDs        []string `json:"station_ids"`
	ScreenIDs         []string `json:"screen_ids"`
	Export            bool     `json:"export"`
	Control           bool     `json:"control"`
	GrantControl      bool     `json:"grant_control"`
}

func (g Grants) Has(role string) bool { return slices.Contains(g.Roles, role) }
func (g Grants) Develop() bool        { return g.Has("engineer") && g.AllStations }
func (g Grants) Manage() bool         { return g.Has("admin") && g.AllStations }
func (g Grants) Station(id string) bool {
	return g.AllStations || (id != "" && slices.Contains(g.StationIDs, id))
}
func (g Grants) Screen(id, stationID string) bool {
	return g.Station(stationID) || slices.Contains(g.ScreenIDs, id)
}
func (g Grants) Validate() error {
	if len(g.Roles) == 0 || len(g.Roles) > 5 || len(g.StationIDs) > 1000 || len(g.ScreenIDs) > 1000 || len(g.ExternalScreenIDs) > 256 {
		return ErrDenied
	}
	for _, role := range g.Roles {
		if !slices.Contains([]string{"viewer", "operator", "engineer", "admin", "auditor"}, role) {
			return ErrDenied
		}
	}
	return nil
}

// MayGrant prevents role administration from becoming an implicit escalation.
// The initial owner is explicitly provisioned with all grantable capabilities.
func (g Grants) MayGrant(next Grants) bool {
	if !g.Manage() || next.Validate() != nil {
		return false
	}
	for _, role := range next.Roles {
		if role != "viewer" && role != "operator" && !g.Has(role) {
			return false
		}
	}
	return (!next.Control || g.GrantControl) && (!next.GrantControl || g.GrantControl) && (!next.Export || g.Export)
}

type Actor struct {
	ID           string
	Version      int64
	Grants       Grants
	StationNames []string
	// Valid rechecks revocation at the moment an operation actually executes.
	Valid         func() bool
	IdentityValid func() bool // Account policy only, for explicit background execution.
	Audit         func(action, target, result string) error
	// StationID resolves a legacy immutable station key to a persisted identity.
	StationID func(string) string
}

func (a Actor) Active() bool { return a.Valid != nil && a.Valid() }
func (a Actor) Station(name string) bool {
	return a.StationID != nil && a.Grants.Station(a.StationID(name))
}
func (a Actor) Screen(id, station string) bool {
	return a.StationID != nil && a.Grants.Screen(id, a.StationID(station))
}

type contextKey struct{}

func WithActor(ctx context.Context, actor Actor) context.Context {
	return context.WithValue(ctx, contextKey{}, actor)
}
func FromContext(ctx context.Context) (Actor, bool) {
	a, ok := ctx.Value(contextKey{}).(Actor)
	return a, ok
}
