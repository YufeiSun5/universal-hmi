package externaldata

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestIntensityPagesAreAuthorizedSeparately(t *testing.T) {
	s, source, _ := fixture(t)
	parent, err := s.SaveScreen(context.Background(), Screen{Name: "能耗管理", Kind: "energy", SourceID: source.ID})
	if err != nil {
		t.Fatal(err)
	}
	heatID := intensityPageID(parent.ID, "heat")
	waterID := intensityPageID(parent.ID, "water")
	waterViewer := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{waterID}})
	menus, err := s.Screens(waterViewer)
	if err != nil || len(menus) != 1 || menus[0].ID != waterID || menus[0].Name != "水单耗" {
		t.Fatalf("unexpected menus: %+v, %v", menus, err)
	}
	date := time.Now().In(beijing).Format("2006-01-02")
	query := Request{Mode: "intensity", Period: "daily", Date: date}
	parentViewer := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{parent.ID}})
	if _, err := s.Query(parentViewer, parent.ID, query); !errors.Is(err, authorization.ErrDenied) {
		t.Fatalf("legacy route bypassed single-page permission: %v", err)
	}
	query.Metric = "water"
	if _, err := s.Query(parentViewer, parent.ID, query); !errors.Is(err, authorization.ErrDenied) {
		t.Fatalf("legacy water request bypassed single-page permission: %v", err)
	}
	if _, err := s.Query(waterViewer, heatID, query); !errors.Is(err, authorization.ErrDenied) {
		t.Fatalf("water grant covered heat page: %v", err)
	}
	query.Metric = "heat"
	if _, err := s.Query(waterViewer, waterID, query); err == nil {
		t.Fatal("water page accepted a different metric")
	}
	query.Metric = ""
	mock := mockDB(t, s)
	mock.ExpectQuery("SELECT TOP \\(257\\)").WillReturnRows(sqlmock.NewRows([]string{"StationCode", "StationName"}).AddRow("02-002-01", "北三南线"))
	mock.ExpectQuery("EXEC dbo.usp_查询站区日结算").WithArgs(date, date, "02-002-01").
		WillReturnRows(sqlmock.NewRows([]string{"统计日期", "站区编码", "测点编码", "单位", "完整日用量"}).AddRow(date, "02-002-01", "ER_MakeupFlowTotal", "t", "5"))
	mock.ExpectClose()
	result, err := s.Query(waterViewer, waterID, query)
	if err != nil || len(result.Statistics) != 1 || result.Statistics[0].Metric != "water" {
		t.Fatalf("independently granted water request failed: %+v, %v", result.Statistics, err)
	}
}

func TestIntensityPageStylePersistsOnlyForItsScreen(t *testing.T) {
	s, source, _ := fixture(t)
	ctx := context.Background()
	parent, err := s.SaveScreen(ctx, Screen{Name: "能耗管理", Kind: "energy", SourceID: source.ID})
	if err != nil {
		t.Fatal(err)
	}
	_, heat, err := s.source(ctx, intensityPageID(parent.ID, "heat"), true)
	if err != nil {
		t.Fatal(err)
	}
	heat.ReportLayouts = map[string]ReportLayout{"statistics_intensity": {
		HeaderColor: "#AABBCC", Columns: []ReportColumn{{Key: "intensity", Label: "热单耗", Visible: true}},
	}}
	viewer := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{heat.ID}})
	if _, err = s.SaveScreen(viewer, heat); !errors.Is(err, authorization.ErrDenied) {
		t.Fatalf("viewer changed layout: %v", err)
	}
	saved, err := s.SaveScreen(ctx, heat)
	if err != nil || saved.Revision != heat.Revision+1 {
		t.Fatalf("saving style: %+v %v", saved, err)
	}
	if _, err = s.SaveScreen(ctx, heat); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale style write: %v", err)
	}
	_, reloaded, err := s.source(viewer, saved.ID, true)
	if err != nil || reloaded.ReportLayouts["statistics_intensity"].HeaderColor != "#AABBCC" {
		t.Fatalf("style readback: %+v, %v", reloaded, err)
	}
	for _, id := range []string{parent.ID, intensityPageID(parent.ID, "water"), intensityPageID(parent.ID, "electricity")} {
		_, sibling, err := s.source(ctx, id, true)
		if err != nil || len(sibling.ReportLayouts) != 0 {
			t.Fatalf("sibling changed: %+v, %v", sibling, err)
		}
	}
	if err := s.Delete(ctx, "screens", parent.ID, parent.Revision); err != nil {
		t.Fatal(err)
	}
	config, err := s.load()
	if err != nil || len(config.IntensityStyles) != 0 {
		t.Fatalf("orphaned style remained: %+v, %v", config.IntensityStyles, err)
	}
}
