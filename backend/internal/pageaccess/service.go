// Package pageaccess composes existing read scopes into the runtime navigation
// contract. Preferences cannot grant access, and page visibility never replaces
// authorization performed by each underlying business service.
package pageaccess

import (
	"context"
	"errors"
	"slices"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/overview"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

type Destination struct {
	ID         string `json:"id"`
	Page       int    `json:"page"`
	Label      string `json:"label"`
	Configured bool   `json:"configured"`
	Mobile     bool   `json:"mobile"`
}
type Result struct {
	Pages       []Destination        `json:"pages"`
	Preferences identity.Preferences `json:"preferences"`
}
type Screens interface {
	VisibleList(context.Context, string, bool) ([]process.Summary, error)
}
type External interface {
	Screens(context.Context) ([]externaldata.Screen, error)
}
type Reports interface {
	Catalog(context.Context) ([]map[string]any, error)
}
type Overview interface {
	Get(context.Context, map[string]bool) (overview.Config, error)
}
type Accounts interface {
	Preferences(authorization.Actor) (identity.Preferences, error)
	SavePreferences(authorization.Actor, identity.Preferences) (identity.Preferences, error)
}
type Service struct {
	Screens       Screens
	External      External
	Reports       Reports
	Overview      Overview
	Accounts      Accounts
	SupplierSites bool
}

func (s *Service) Catalog(ctx context.Context) (Result, error) {
	out := Result{Pages: []Destination{}}
	a, ok := authorization.FromContext(ctx)
	if !ok || a.ID == "" || !a.Active() {
		return out, authorization.ErrDenied
	}
	g := a.Grants
	scope := g.AllStations || len(a.StationNames) > 0
	add := func(id string, page int, label string, allowed, configured, mobile bool) {
		if allowed {
			out.Pages = append(out.Pages, Destination{id, page, label, configured, mobile})
		}
	}
	hasGIS, hasProcess := false, false
	if s.Screens != nil {
		rows, e := s.Screens.VisibleList(ctx, "", true)
		if e != nil {
			return out, e
		}
		for _, row := range rows {
			if row.Kind == "gis" {
				hasGIS = true
			} else {
				hasProcess = true
			}
		}
	}
	add("gis", 11, "GIS", g.AllStations || hasGIS, hasGIS, true)
	add("process", 9, "工艺画面", scope || hasProcess, hasProcess, true)
	overviewConfigured := false
	if s.Overview != nil && scope {
		c, e := s.Overview.Get(ctx, map[string]bool{})
		if e != nil {
			return out, e
		}
		overviewConfigured = len(c.Rows) > 0
	}
	add("overview", 16, "数据总览", scope, overviewConfigured, true)
	// Equipment and alarm pages remain available with an authorized station,
	// including when the warehouse has no devices or there are no alarm records.
	add("equipment", 13, "设备台账", scope, true, true)

	hasHistory, hasEnergy, hasAlarms := false, false, false
	if s.External != nil {
		screens, e := s.External.Screens(ctx)
		if e != nil {
			return out, e
		}
		for _, screen := range screens {
			// Screens() also lists configuration for administrators; that does not
			// itself authorize reading the underlying historical data.
			if !(a.ReadAllExternalScreens || g.Develop() || slices.Contains(g.ExternalScreenIDs, screen.ID)) {
				continue
			}
			hasHistory = true
			if screen.Kind == "alarm" {
				hasAlarms = true
			}
			if screen.Kind == "energy" || screen.Kind == "comparison" {
				hasEnergy = true
			}
		}
	}
	add("alarms", 17, "报警记录", hasAlarms || g.Develop() || a.ReadAllExternalScreens, hasAlarms, true)
	add("history", 12, "历史", hasHistory || g.Develop() || a.ReadAllExternalScreens, hasHistory, true)
	add("energy", 18, "能耗管理", hasEnergy || g.Develop() || a.ReadAllExternalScreens, hasEnergy, true)
	hasReports := false
	if s.Reports != nil && g.AllStations {
		rows, e := s.Reports.Catalog(ctx)
		if e != nil {
			return out, e
		}
		hasReports = len(rows) > 0
	}
	add("total-reports", 19, "总统计报表", g.AllStations, hasReports, true)
	for _, m := range []struct {
		id, label string
		allowed   bool
	}{
		{"applications", "申请与审批", g.MaterialsRequest || g.MaterialsApprove},
		{"catalog", "品类管理", g.MaterialsCatalog}, {"inbound", "入库管理", g.MaterialsInbound},
		{"stock", "库存管理", g.MaterialsInbound || g.MaterialsOutbound || g.MaterialsCatalog},
		{"outbound", "出库管理", g.MaterialsOutbound},
		{"chains", "操作日志", g.MaterialsRequest || g.MaterialsApprove || g.MaterialsInbound || g.MaterialsOutbound || g.MaterialsCatalog},
	} {
		add("materials/"+m.id, 20, "物料管理 · "+m.label, m.allowed, true, false)
	}
	// The existing supplier capability is granted to every authenticated account.
	// This is not a newly introduced module grant or a proxy for write access.
	add("qiwei", 14, "七维科技", s.SupplierSites, true, true)
	add("boer", 15, "沈阳波尔", s.SupplierSites, true, true)
	add("workbench", 6, "开发工作台", g.Develop(), true, false)
	if s.Accounts != nil {
		var e error
		out.Preferences, e = s.Accounts.Preferences(a)
		if e != nil {
			return out, e
		}
	}
	if !a.Active() {
		return Result{}, authorization.ErrDenied
	}
	return out, nil
}
func (s *Service) SaveHome(ctx context.Context, in identity.Preferences) (identity.Preferences, error) {
	if s.Accounts == nil {
		return identity.Preferences{}, authorization.ErrDenied
	}
	catalog, e := s.Catalog(ctx)
	if e != nil {
		return identity.Preferences{}, e
	}
	if in.Home != "" {
		allowed := false
		for _, p := range catalog.Pages {
			if p.ID == in.Home && p.Configured {
				allowed = true
				break
			}
		}
		if !allowed {
			return identity.Preferences{}, errors.New("该首页已删除、未配置或没有访问权限，请重新选择")
		}
	}
	a, _ := authorization.FromContext(ctx)
	return s.Accounts.SavePreferences(a, in)
}
