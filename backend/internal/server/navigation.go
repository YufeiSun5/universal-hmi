package server

import (
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/navigation"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"net/http"
)

func registerNavigation(mux *http.ServeMux, store navigation.Store, screens *process.Service) *navigation.Service {
	svc := navigation.New(store, func(id string) error { _, err := screens.Get(id); return err })
	respond := func(w http.ResponseWriter, c navigation.Config, err error) {
		switch {
		case err == nil:
			writeJSON(w, 200, c)
		case errors.Is(err, navigation.ErrConflict):
			writeError(w, 409, "navigation_conflict", "菜单已由其他窗口修改，请重新打开配置")
		case errors.Is(err, navigation.ErrInvalid):
			writeError(w, 422, "invalid_navigation", err.Error())
		default:
			writeError(w, 500, "navigation_failed", "菜单配置读取或保存失败")
		}
	}
	mux.HandleFunc("GET /api/v1/navigation", func(w http.ResponseWriter, r *http.Request) {
		c, err := svc.Get()
		if a, ok := authorization.FromContext(r.Context()); ok && err == nil {
			if !a.Active() {
				outcome(w, nil, authorization.ErrDenied)
				return
			}
			// Several menu entries may refer to one screen. Read only persisted
			// identity/ownership once per request; never hydrate its artwork here.
			type summaryResult struct {
				doc process.Summary
				err error
			}
			known := map[string]summaryResult{}
			var prune func([]navigation.Node) []navigation.Node
			prune = func(nodes []navigation.Node) []navigation.Node {
				out := []navigation.Node{}
				for _, n := range nodes {
					if n.ScreenID != "" {
						result, found := known[n.ScreenID]
						if !found {
							result.doc, result.err = screens.GetSummary(n.ScreenID)
							known[n.ScreenID] = result
						}
						if result.err != nil || !a.Screen(result.doc.ID, result.doc.Station) {
							continue
						}
					} else {
						n.Children = prune(n.Children)
						if len(n.Children) == 0 {
							continue
						}
					}
					out = append(out, n)
				}
				return out
			}
			c.Nodes = prune(c.Nodes)
			if !a.Active() {
				outcome(w, nil, authorization.ErrDenied)
				return
			}
		}
		respond(w, c, err)
	})
	mux.HandleFunc("PUT /api/v1/navigation", func(w http.ResponseWriter, r *http.Request) {
		var c navigation.Config
		if !decode(w, r, &c) {
			return
		}
		saved, err := svc.Save(c)
		respond(w, saved, err)
	})
	return svc
}
