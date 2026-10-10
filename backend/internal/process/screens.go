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
	MaxScreens       = 64
	MaxNodes         = 1000
	MaxImageBytes    = 2 * 1024 * 1024
)

var (
	ErrInvalid      = errors.New("invalid process screen")
	ErrConflict     = errors.New("process screen revision changed")
	ErrNotFound     = errors.New("process screen not found")
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

type Document struct {
	SchemaVersion int              `json:"schema_version"`
	ID            string           `json:"id"`
	Revision      int64            `json:"revision"`
	Name          string           `json:"name"`
	Station       string           `json:"station"`
	Width         float64          `json:"width"`
	Height        float64          `json:"height"`
	Nodes         []Node           `json:"nodes"`
	Assets        map[string]Asset `json:"assets"`
}

type Summary struct {
	ID       string `json:"id"`
	Revision int64  `json:"revision"`
	Name     string `json:"name"`
	Station  string `json:"station"`
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
	mu        sync.Mutex
	dir       string
	materials map[string]MaterialSummary
}

// Each document is written independently, limiting memory and preventing one
// screen save from replacing another screen. Startup fails on corrupt documents.
func Open(dir string) (*Service, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &Service{dir: dir}
	if err := s.openMaterials(); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	count := 0
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".json")
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
	return s, nil
}

func (s *Service) read(id string) (Document, error) {
	var d Document
	if !idPattern.MatchString(id) {
		return d, ErrInvalid
	}
	path := filepath.Join(s.dir, id+".json")
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return d, ErrNotFound
	}
	if err != nil {
		return d, err
	}
	if info.Size() > MaxDocumentBytes {
		return d, ErrInvalid
	}
	b, err := os.ReadFile(path)
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
	return s.read(id)
}

func (s *Service) list(station string, all bool) ([]Summary, error) {
	items := make([]Summary, 0)
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		d, err := s.read(strings.TrimSuffix(entry.Name(), ".json"))
		if err != nil {
			return nil, err
		}
		if all || d.Station == station {
			items = append(items, Summary{d.ID, d.Revision, d.Name, d.Station})
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

func (s *Service) List(station string) ([]Summary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.list(station, false)
}

func (s *Service) Save(d Document) (Document, error) {
	d = canonical(d)
	if err := Validate(d); err != nil {
		return Document{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	previous, err := s.read(d.ID)
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
	} else if previous.Revision != d.Revision || previous.Station != d.Station {
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
	if err := writeAtomic(s.dir, d.ID, b); err != nil {
		return Document{}, err
	}
	return d, nil
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
	return os.Remove(filepath.Join(s.dir, id+".json"))
}

func finiteRange(n, min, max float64) bool {
	return !math.IsNaN(n) && !math.IsInf(n, 0) && n >= min && n <= max
}

func Validate(d Document) error {
	invalid := func(message string) error { return fmt.Errorf("%w: %s", ErrInvalid, message) }
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
