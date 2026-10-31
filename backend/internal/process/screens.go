// Package process owns editable process-screen documents, not acquisition or control.
package process

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

const (
	MaxDocumentBytes = 8 * 1024 * 1024
	MaxScreens       = 512
	MaxNodes         = 1000
	MaxImageBytes    = 2 * 1024 * 1024
)

var (
	ErrInvalid      = errors.New("invalid process screen")
	ErrConflict     = errors.New("process screen revision changed")
	ErrNotFound     = errors.New("process screen not found")
	ErrInUse        = errors.New("public screen is in use")
	idPattern       = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,96}$`)
	colorPattern    = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)
	pipePortPattern = regexp.MustCompile(`^path:(0(?:\.\d{1,12})?|1(?:\.0{1,12})?)$`)
)

type Position struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

type ArrowCondition struct {
	Slot     string   `json:"slot"`
	PointID  string   `json:"point_id"`
	Operator string   `json:"operator"`
	Value    *float64 `json:"value"`
}

type ArrowRule struct {
	Match      string           `json:"match"`
	Conditions []ArrowCondition `json:"conditions"`
}

type Node struct {
	ID               string     `json:"id"`
	Kind             string     `json:"kind"`
	X                float64    `json:"x"`
	Y                float64    `json:"y"`
	Width            float64    `json:"width"`
	Height           float64    `json:"height"`
	Rotation         int        `json:"rotation"`
	Text             string     `json:"text"`
	Label            string     `json:"label,omitempty"`
	Symbol           string     `json:"symbol"`
	Image            string     `json:"image"`
	Color            string     `json:"color"`
	Fill             string     `json:"fill"`
	StrokeWidth      float64    `json:"stroke_width"`
	FontSize         float64    `json:"font_size"`
	PointID          string     `json:"point_id"`
	Decimals         int        `json:"decimals"`
	ShowUnit         bool       `json:"show_unit"`
	UnitOverride     string     `json:"unit_override"`
	Arrow            bool       `json:"arrow"`
	PipeStyle        string     `json:"pipe_style,omitempty"`
	PipeRounded      bool       `json:"pipe_rounded,omitempty"`
	PipeElbows       bool       `json:"pipe_elbows,omitempty"`
	PipeBendRadius   *float64   `json:"pipe_bend_radius,omitempty"`
	ArrowMode        string     `json:"arrow_mode,omitempty"`
	ArrowSpacing     *float64   `json:"arrow_spacing,omitempty"`
	ArrowCount       *int       `json:"arrow_count,omitempty"`
	ArrowAnimate     bool       `json:"arrow_animate,omitempty"`
	ArrowReverse     bool       `json:"arrow_reverse,omitempty"`
	ArrowSpeed       *float64   `json:"arrow_speed,omitempty"`
	ArrowVisibleRule *ArrowRule `json:"arrow_visible_rule,omitempty"`
	ArrowMotionRule  *ArrowRule `json:"arrow_motion_rule,omitempty"`
	Orthogonal       bool       `json:"orthogonal"`
	Points           []Position `json:"points"`
	StartNode        string     `json:"start_node"`
	StartPort        string     `json:"start_port"`
	EndNode          string     `json:"end_node"`
	EndPort          string     `json:"end_port"`
}

type Asset struct {
	Name string `json:"name"`
	MIME string `json:"mime"`
	Data string `json:"data"` // Embedded standard base64; never a remote URL or filesystem path.
}

type Background struct {
	Type     string   `json:"type"`
	Color    string   `json:"color"`
	Opacity  *float64 `json:"opacity"`
	EndColor string   `json:"end_color,omitempty"`
	Angle    *float64 `json:"angle,omitempty"`
	Image    string   `json:"image,omitempty"`
	Fit      string   `json:"fit,omitempty"`
}

// UnmarshalJSON enforces the discriminated background contract, including
// presence and rejection of fields belonging to a different background type.
func (b *Background) UnmarshalJSON(data []byte) error {
	type plain Background
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	var kind string
	if err := json.Unmarshal(fields["type"], &kind); err != nil {
		return fmt.Errorf("background type required")
	}
	required := []string{"type", "color", "opacity"}
	switch kind {
	case "solid":
	case "linear":
		required = append(required, "end_color", "angle")
	case "image":
		required = append(required, "image", "fit")
	default:
		return fmt.Errorf("invalid background type")
	}
	if len(fields) != len(required) {
		return fmt.Errorf("invalid background fields")
	}
	for _, key := range required {
		v, ok := fields[key]
		if !ok || string(v) == "null" {
			return fmt.Errorf("background field %s required", key)
		}
	}
	var value plain
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*b = Background(value)
	return nil
}

type Document struct {
	Background       *Background               `json:"background,omitempty"`
	TemplateID       string                    `json:"template_id,omitempty"`
	TemplateRevision int64                     `json:"template_revision,omitempty"`
	Bindings         map[string]ElementBinding `json:"bindings,omitempty"`
	GIS              *GISConfig                `json:"gis,omitempty"`
	Kind             string                    `json:"kind,omitempty"` // Empty legacy documents are process screens.
	SchemaVersion    int                       `json:"schema_version"`
	ID               string                    `json:"id"`
	Revision         int64                     `json:"revision"`
	Name             string                    `json:"name"`
	Station          string                    `json:"station"`
	Width            float64                   `json:"width"`
	Height           float64                   `json:"height"`
	Nodes            []Node                    `json:"nodes"`
	Assets           map[string]Asset          `json:"assets"`
}

func (d *Document) UnmarshalJSON(data []byte) error {
	type plain Document
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	if value, ok := fields["background"]; ok && string(value) == "null" {
		return fmt.Errorf("background must be an object")
	}
	var parsed plain
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&parsed); err != nil {
		return err
	}
	*d = Document(parsed)
	return nil
}

type GISStation struct {
	TargetScreenID string            `json:"target_screen_id,omitempty"`
	ID             string            `json:"id"`
	Name           string            `json:"name"`
	Longitude      float64           `json:"longitude"`
	Latitude       float64           `json:"latitude"`
	Bindings       map[string]string `json:"bindings,omitempty"`
	Zones          []GISZone         `json:"zones,omitempty"`
}

// Zones are ordered presentation sections, not point ownership or stations.
type GISZone struct {
	ID       string            `json:"id"`
	Name     string            `json:"name"`
	Bindings map[string]string `json:"bindings,omitempty"`
}

func (s GISStation) BindingGroups() []map[string]string {
	groups := []map[string]string{s.Bindings}
	for _, zone := range s.Zones {
		groups = append(groups, zone.Bindings)
	}
	return groups
}

type GISConfig struct {
	Stations []GISStation `json:"stations"`
}

type Summary struct {
	TemplateID       string `json:"template_id,omitempty"`
	TemplateRevision int64  `json:"template_revision,omitempty"`
	Kind             string `json:"kind,omitempty"`
	ID               string `json:"id"`
	Revision         int64  `json:"revision"`
	Name             string `json:"name"`
	Station          string `json:"station"`
}

func canonical(d Document) Document {
	d.Nodes = append(make([]Node, 0, len(d.Nodes)), d.Nodes...)
	if d.Assets == nil {
		d.Assets = map[string]Asset{}
	}
	for i := range d.Nodes {
		if d.Nodes[i].ArrowMode == "segments" {
			d.Nodes[i].ArrowMode = "count"
		}
		if d.Nodes[i].Points == nil {
			d.Nodes[i].Points = []Position{}
		}
	}
	return d
}

type Service struct {
	stationCheck func(string) error
	documents    DocumentStore
	mu           sync.Mutex
	dir          string
	materials    map[string]MaterialSummary
}

// Each document is written independently, limiting memory and preventing one
// screen save from replacing another screen. Startup fails on corrupt documents.
func Open(dir string) (*Service, error) { return OpenDocuments(dir, nil) }
func OpenDocuments(dir string, documents DocumentStore) (*Service, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &Service{dir: dir, documents: documents}
	if err := s.openMaterials(); err != nil {
		return nil, err
	}
	entries, err := s.names(dir)
	if err != nil {
		return nil, err
	}
	count := 0
	for _, id := range entries {
		if !idPattern.MatchString(id) {
			return nil, fmt.Errorf("invalid screen filename")
		}
		d, err := s.read(id)
		if err != nil {
			return nil, err
		}
		if d.ID != id || d.Revision < 1 {
			return nil, fmt.Errorf("invalid screen identity/revision")
		}
		if err := Validate(d); err != nil {
			return nil, err
		}
		count++
	}
	if count > MaxScreens {
		return nil, fmt.Errorf("screen limit exceeded")
	}
	for _, id := range entries {
		d, err := s.read(id)
		if err != nil {
			return nil, err
		}
		resolved, err := s.resolve(d)
		if err != nil {
			return nil, err
		}
		if err := validate(resolved, true); err != nil {
			return nil, err
		}
	}
	return s, nil
}

func (s *Service) read(id string) (Document, error) {
	var d Document
	if !idPattern.MatchString(id) {
		return d, ErrInvalid
	}
	b, err := s.bytes(s.dir, id, MaxDocumentBytes)
	if errors.Is(err, os.ErrNotExist) {
		return d, ErrNotFound
	}
	if err != nil {
		return d, err
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&d); err != nil {
		return d, err
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return d, fmt.Errorf("trailing JSON in screen document")
	}
	return canonical(d), nil
}

func (s *Service) Get(id string) (Document, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, err := s.read(id)
	if err != nil {
		return d, err
	}
	return s.resolve(d)
}

func (s *Service) list(station string, all bool) ([]Summary, error) {
	items := make([]Summary, 0)
	entries, err := s.names(s.dir)
	if err != nil {
		return nil, err
	}
	for _, id := range entries {
		d, err := s.read(id)
		if err != nil {
			return nil, err
		}
		if all || d.Station == station {
			if d.TemplateID != "" {
				t, err := s.read(d.TemplateID)
				if err != nil {
					return nil, err
				}
				d.TemplateRevision = t.Revision
			}
			items = append(items, Summary{Kind: d.Kind, ID: d.ID, Revision: d.Revision, Name: d.Name, Station: d.Station, TemplateID: d.TemplateID, TemplateRevision: d.TemplateRevision})
		}
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].Name == items[j].Name {
			return items[i].ID < items[j].ID
		}
		return items[i].Name < items[j].Name
	})
	return items, nil
}

func (s *Service) ListAll() ([]Summary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.list("", true)
}

func (s *Service) List(station string) ([]Summary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.list(station, false)
}

func (s *Service) Save(d Document) (Document, error) {
	return s.SaveWithPoints(d, nil)
}

// SaveWithPoints validates station bindings at the application boundary. Layout
// is owned by the public source; an instance only persists binding overrides.
func (s *Service) SaveWithPoints(d Document, pointStation func(string) (string, bool)) (Document, error) {
	return s.saveWithPoints(d, pointStation, false)
}

// SaveAuthorizedPoints permits explicit cross-station references only through an authorized lookup.
func (s *Service) SaveAuthorizedPoints(d Document, lookup func(string) (string, bool)) (Document, error) {
	if lookup == nil {
		return Document{}, fmt.Errorf("%w: authorized point lookup required", ErrInvalid)
	}
	check := func(id string) error {
		if id != "" {
			if _, ok := lookup(id); !ok {
				return fmt.Errorf("%w: binding point is missing or denied", ErrInvalid)
			}
		}
		return nil
	}
	if d.GIS != nil {
		for _, station := range d.GIS.Stations {
			for _, group := range station.BindingGroups() {
				for _, id := range group {
					if e := check(id); e != nil {
						return Document{}, e
					}
				}
			}
		}
	}
	for _, n := range d.Nodes {
		if e := check(n.PointID); e != nil {
			return Document{}, e
		}
		for _, rule := range []*ArrowRule{n.ArrowVisibleRule, n.ArrowMotionRule} {
			if rule != nil {
				for _, c := range rule.Conditions {
					if e := check(c.PointID); e != nil {
						return Document{}, e
					}
				}
			}
		}
	}
	return s.saveWithPoints(d, lookup, true)
}
func (s *Service) saveWithPoints(d Document, pointStation func(string) (string, bool), cross bool) (Document, error) {
	d = canonical(d)
	// Legacy documents remain readable without silently widening their grants.
	// Every new save must follow the engineering-level GIS ownership contract.
	if d.Kind == "gis" && d.Station != "" {
		return Document{}, fmt.Errorf("%w: GIS 是工程级公共驾驶舱，不能归属站点；请在公共画面中创建", ErrInvalid)
	}
	if err := Validate(d); err != nil {
		return Document{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stationCheck != nil {
		if err := s.stationCheck(d.Station); err != nil {
			return Document{}, fmt.Errorf("%w: %v", ErrInvalid, err)
		}
	}
	if d.TemplateID != "" {
		t, err := s.read(d.TemplateID)
		if err != nil || t.Station != "" || t.Kind == "gis" || t.TemplateID != "" {
			return Document{}, fmt.Errorf("%w: 请选择已保存的公共工艺画面", ErrInvalid)
		}
		if t.Revision != d.TemplateRevision {
			return Document{}, ErrConflict
		}
		resolved, err := s.resolve(d)
		if err != nil {
			return Document{}, err
		}
		if err := validateInstanceBindings(d, t, pointStation, cross); err != nil {
			return Document{}, err
		}
		if err := validate(resolved, true); err != nil {
			return Document{}, err
		}
		// Never persist a layout snapshot in the instance.
		d.Nodes = []Node{}
		d.Assets = map[string]Asset{}
		d.Width, d.Height = t.Width, t.Height
	}
	previous, err := s.read(d.ID)
	if d.GIS != nil {
		for _, station := range d.GIS.Stations {
			if station.TargetScreenID == "" {
				continue
			}
			target, targetErr := s.read(station.TargetScreenID)
			if targetErr != nil || target.Kind == "gis" {
				return Document{}, fmt.Errorf("%w: GIS 跳转目标必须是已保存的工艺画面", ErrInvalid)
			}
		}
	}
	if err != nil && !errors.Is(err, ErrNotFound) {
		return Document{}, err
	}
	if errors.Is(err, ErrNotFound) {
		if d.Revision != 0 {
			return Document{}, ErrConflict
		}
		items, err := s.list("", true)
		if err != nil {
			return Document{}, err
		}
		if len(items) >= MaxScreens {
			return Document{}, fmt.Errorf("%w: at most %d screens", ErrInvalid, MaxScreens)
		}
	} else if previous.Revision != d.Revision || previous.Station != d.Station || previous.TemplateID != d.TemplateID || (previous.Kind == "gis") != (d.Kind == "gis") {
		return Document{}, ErrConflict
	}
	d.Revision++
	b, err := json.Marshal(d)
	if err != nil {
		return Document{}, err
	}
	if len(b) > MaxDocumentBytes {
		return Document{}, fmt.Errorf("%w: document too large", ErrInvalid)
	}
	if err := s.write(s.dir, d.ID, b); err != nil {
		return Document{}, err
	}
	return s.resolve(d)
}

func writeAtomic(dir, id string, b []byte) error {
	f, err := os.CreateTemp(dir, ".process-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(b); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), filepath.Join(dir, id+".json"))
}

func (s *Service) Delete(id string, revision int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, err := s.read(id)
	if err != nil {
		return err
	}
	if revision != d.Revision {
		return ErrConflict
	}
	items, err := s.list("", true)
	if err != nil {
		return err
	}
	for _, item := range items {
		if item.TemplateID == id {
			return fmt.Errorf("%w: %s / %s", ErrInUse, item.Station, item.Name)
		}
	}
	return s.remove(s.dir, id)
}

func finiteRange(n, min, max float64) bool {
	return !math.IsNaN(n) && !math.IsInf(n, 0) && n >= min && n <= max
}

func Validate(d Document) error { return validate(d, false) }

func validate(d Document, resolved bool) error {
	invalid := func(message string) error { return fmt.Errorf("%w: %s", ErrInvalid, message) }
	if d.TemplateID != "" {
		if d.Background != nil && !resolved {
			return invalid("公共画面实例不能覆盖背景")
		}
		if !idPattern.MatchString(d.TemplateID) || d.TemplateID == d.ID || strings.TrimSpace(d.Station) == "" || d.Kind == "gis" || d.TemplateRevision < 1 || len(d.Bindings) > MaxNodes {
			return invalid("公共画面关联、目标站点或绑定数量无效")
		}
	} else if len(d.Bindings) != 0 || d.TemplateRevision != 0 {
		return invalid("独立画面不能携带公共画面绑定")
	}
	if d.Kind != "" && d.Kind != "process" && d.Kind != "gis" {
		return invalid("unsupported screen kind")
	}
	if d.Kind == "gis" && (len(d.Nodes) != 0 || len(d.Assets) != 0 || d.Background != nil) {
		return invalid("GIS screen cannot contain process nodes/assets")
	}
	if d.GIS != nil {
		if d.Kind != "gis" || len(d.GIS.Stations) > 100 {
			return invalid("GIS station limit or screen kind")
		}
		seen := map[string]bool{}
		for _, station := range d.GIS.Stations {
			if station.TargetScreenID != "" && !idPattern.MatchString(station.TargetScreenID) {
				return invalid("GIS target screen identity")
			}
			if !idPattern.MatchString(station.ID) || seen[station.ID] || strings.TrimSpace(station.Name) == "" || len(station.Name) > 256 || !finiteRange(station.Longitude, -180, 180) || !finiteRange(station.Latitude, -85, 85) {
				return invalid("GIS station identity/name/coordinates")
			}
			seen[station.ID] = true
			if len(station.Zones) > 16 {
				return invalid("GIS zone limit")
			}
			zoneIDs := map[string]bool{}
			for _, zone := range station.Zones {
				if !idPattern.MatchString(zone.ID) || zoneIDs[zone.ID] || strings.TrimSpace(zone.Name) == "" || len(zone.Name) > 256 {
					return invalid("GIS zone identity/name")
				}
				zoneIDs[zone.ID] = true
			}
			for _, group := range station.BindingGroups() {
				for metric, pointID := range group {
					switch metric {
					case "primary_supply", "primary_return", "secondary_supply", "secondary_return", "supply_pressure":
					default:
						return invalid("unsupported GIS metric")
					}
					if !idPattern.MatchString(pointID) {
						return invalid("GIS binding point identity")
					}
				}
			}
		}
	}
	if d.SchemaVersion != 1 || !idPattern.MatchString(d.ID) || d.Revision < 0 || d.Revision >= 9007199254740991 {
		return invalid("unsupported schema or identity/revision")
	}
	if strings.TrimSpace(d.Name) == "" || len(d.Name) > 256 || len(d.Station) > 256 {
		return invalid("name/station length")
	}
	if !finiteRange(d.Width, 320, 8192) || !finiteRange(d.Height, 240, 8192) {
		return invalid("canvas size")
	}
	if d.Nodes == nil || len(d.Nodes) > MaxNodes || len(d.Assets) > 64 {
		return invalid("node/asset limit")
	}
	nodes := map[string]Node{}
	usedAssets := map[string]bool{}
	if b := d.Background; b != nil {
		if !colorPattern.MatchString(b.Color) || b.Opacity == nil || !finiteRange(*b.Opacity, 0, 1) {
			return invalid("background color/opacity")
		}
		switch b.Type {
		case "solid":
			if b.EndColor != "" || b.Angle != nil || b.Image != "" || b.Fit != "" {
				return invalid("solid background fields")
			}
		case "linear":
			if !colorPattern.MatchString(b.EndColor) || b.Angle == nil || !finiteRange(*b.Angle, 0, 360) || b.Image != "" || b.Fit != "" {
				return invalid("linear background fields")
			}
		case "image":
			if b.EndColor != "" || b.Angle != nil || !idPattern.MatchString(b.Image) || (b.Fit != "cover" && b.Fit != "contain" && b.Fit != "fill") {
				return invalid("image background fields")
			}
			if _, ok := d.Assets[b.Image]; !ok {
				return invalid("missing background image")
			}
			usedAssets[b.Image] = true
		default:
			return invalid("background type")
		}
	}
	for _, n := range d.Nodes {
		if !idPattern.MatchString(n.ID) {
			return invalid("node identity")
		}
		if _, ok := nodes[n.ID]; ok {
			return invalid("duplicate node identity")
		}
		nodes[n.ID] = n
		if n.PipeBendRadius != nil && !finiteRange(*n.PipeBendRadius, 1, 128) || n.Kind != "pipe" && (n.PipeRounded || n.PipeElbows || n.PipeBendRadius != nil) {
			return invalid("pipe bend settings")
		}
		if n.PipeStyle != "" && (n.Kind != "pipe" || n.PipeStyle != "flat" && n.PipeStyle != "cylinder") {
			return invalid("pipe appearance")
		}
		if n.ArrowMode != "" && n.ArrowMode != "single" && n.ArrowMode != "spacing" && n.ArrowMode != "count" && n.ArrowMode != "segments" ||
			n.ArrowSpacing != nil && !finiteRange(*n.ArrowSpacing, 12, 2000) ||
			n.ArrowCount != nil && (*n.ArrowCount < 1 || *n.ArrowCount > 64) ||
			n.ArrowSpeed != nil && !finiteRange(*n.ArrowSpeed, 1, 500) {
			return invalid("pipe arrow settings")
		}
		for _, rule := range []*ArrowRule{n.ArrowVisibleRule, n.ArrowMotionRule} {
			if rule == nil {
				continue
			}
			if n.Kind != "pipe" || rule.Match != "all" && rule.Match != "any" || len(rule.Conditions) < 1 || len(rule.Conditions) > 8 {
				return invalid("arrow display rule")
			}
			for _, c := range rule.Conditions {
				if len(c.Slot) > 256 || c.PointID != "" && !idPattern.MatchString(c.PointID) || c.Value == nil || math.IsNaN(*c.Value) || math.IsInf(*c.Value, 0) {
					return invalid("arrow condition value/binding")
				}
				switch c.Operator {
				case ">", "<", ">=", "<=", "==", "!=":
				default:
					return invalid("arrow condition operator")
				}
			}
		}
		if !finiteRange(n.X, 0, d.Width) || !finiteRange(n.Y, 0, d.Height) || !finiteRange(n.Width, 0, d.Width) || !finiteRange(n.Height, 0, d.Height) || n.X+n.Width > d.Width || n.Y+n.Height > d.Height {
			return invalid("node outside canvas")
		}
		if n.Rotation != 0 && n.Rotation != 90 && n.Rotation != 180 && n.Rotation != 270 {
			return invalid("rotation")
		}
		if !colorPattern.MatchString(n.Color) || (n.Fill != "none" && !colorPattern.MatchString(n.Fill)) || !finiteRange(n.StrokeWidth, 1, 32) || !finiteRange(n.FontSize, 8, 128) || n.Decimals < 0 || n.Decimals > 6 || len(n.Text) > 4096 || len(n.Label) > 256 || len(n.PointID) > 128 || len(n.UnitOverride) > 256 {
			return invalid("node style/binding")
		}
		switch n.Kind {
		case "pipe":
			if len(n.Points) < 2 || len(n.Points) > 256 {
				return invalid("pipe requires 2..256 vertices")
			}
			for _, p := range n.Points {
				if !finiteRange(p.X, 0, d.Width) || !finiteRange(p.Y, 0, d.Height) {
					return invalid("pipe vertex")
				}
			}
		case "image":
			if _, ok := d.Assets[n.Image]; !ok {
				return invalid("missing embedded image")
			}
			usedAssets[n.Image] = true
		case "symbol":
			if !idPattern.MatchString(n.Symbol) {
				return invalid("symbol identity")
			}
		case "text", "value", "rect", "ellipse":
		default:
			return invalid("unknown node type")
		}
		if n.Kind != "pipe" && (n.Width < 8 || n.Height < 8 || len(n.Points) != 0 || n.StartNode != "" || n.EndNode != "") {
			return invalid("element dimensions/pipe fields")
		}
	}
	for _, n := range d.Nodes {
		for _, endpoint := range [][2]string{{n.StartNode, n.StartPort}, {n.EndNode, n.EndPort}} {
			if endpoint[0] == "" {
				if endpoint[1] != "" {
					return invalid("port without target")
				}
				continue
			}
			target, ok := nodes[endpoint[0]]
			if !ok || target.ID == n.ID {
				return invalid("pipe connection target")
			}
			if target.Kind == "pipe" {
				if !pipePortPattern.MatchString(endpoint[1]) {
					return invalid("pipe junction position")
				}
				continue
			}
			switch endpoint[1] {
			case "left", "right", "top", "bottom", "left_top", "left_bottom", "right_top", "right_bottom":
			default:
				return invalid("pipe connection port")
			}
		}
	}
	visiting, visited := map[string]bool{}, map[string]bool{}
	var visit func(string) bool
	visit = func(id string) bool {
		if visited[id] {
			return true
		}
		if visiting[id] {
			return false
		}
		visiting[id] = true
		n := nodes[id]
		for _, target := range []string{n.StartNode, n.EndNode} {
			if nodes[target].Kind == "pipe" && !visit(target) {
				return false
			}
		}
		delete(visiting, id)
		visited[id] = true
		return true
	}
	for _, n := range d.Nodes {
		if n.Kind == "pipe" && !visit(n.ID) {
			return invalid("cyclic pipe connections")
		}
	}
	for id, a := range d.Assets {
		if !idPattern.MatchString(id) || !usedAssets[id] {
			return invalid("embedded image metadata/size")
		}
		if _, err := validateAsset(a); err != nil {
			return err
		}
	}
	return nil
}

func validateAsset(a Asset) (image.Config, error) {
	invalid := func(reason string) (image.Config, error) {
		return image.Config{}, fmt.Errorf("%w: %s", ErrInvalid, reason)
	}
	if len(a.Name) > 256 || (a.MIME != "image/png" && a.MIME != "image/jpeg") || len(a.Data) > base64.StdEncoding.EncodedLen(MaxImageBytes) || strings.ContainsAny(a.Data, "\r\n") {
		return invalid("image metadata/size")
	}
	data, err := base64.StdEncoding.Strict().DecodeString(a.Data)
	if err != nil || len(data) == 0 || len(data) > MaxImageBytes {
		return invalid("image base64")
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || "image/"+format != a.MIME || config.Width < 1 || config.Height < 1 || config.Width > 8192 || config.Height > 8192 || int64(config.Width)*int64(config.Height) > 16000000 {
		return invalid("image format/dimensions")
	}
	if _, _, err := image.Decode(bytes.NewReader(data)); err != nil {
		return invalid("corrupt image")
	}
	return config, nil
}

// SetStationCheck installs the station directory application port at composition.
func (s *Service) SetStationCheck(check func(string) error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stationCheck = check
}
