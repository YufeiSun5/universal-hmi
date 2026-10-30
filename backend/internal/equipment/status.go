package equipment

import (
	"context"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

type Signal struct {
	PointID    string `json:"point_id"`
	Expression string `json:"expression"`
}
type Signals struct {
	Fault   *Signal `json:"fault,omitempty"`
	Running *Signal `json:"running,omitempty"`
}
type StatusPorts struct {
	Catalog interface {
		Visible(context.Context) ([]points.Definition, error)
	}
	Live interface {
		ReadPointsFor(context.Context, []string) (map[string]storage.Sample, error)
	}
}
type LiveStatus struct {
	ID          string    `json:"id"`
	Revision    int64     `json:"revision"`
	State       string    `json:"state"`
	Reason      string    `json:"reason,omitempty"`
	EvaluatedAt time.Time `json:"evaluated_at"`
}

func visibleDevice(ctx context.Context, d Device) Device {
	if a, ok := authorization.FromContext(ctx); ok && !a.Grants.Develop() {
		d.Signals = Signals{}
	}
	return d
}

func (s *Service) validateSignals(ctx context.Context, signals Signals) error {
	if signals.Fault == nil && signals.Running == nil {
		return nil
	}
	if s.ports.Catalog == nil {
		return fmt.Errorf("变量目录不可用")
	}
	rows, err := s.ports.Catalog.Visible(ctx)
	if err != nil {
		return err
	}
	index := map[string]points.Definition{}
	for _, p := range rows {
		index[p.ID] = p
	}
	for _, sig := range []*Signal{signals.Fault, signals.Running} {
		if sig == nil {
			continue
		}
		p, ok := index[sig.PointID]
		if !ok || p.DataType == "STRING" {
			return fmt.Errorf("请选择已授权的数值或开关量变量")
		}
		if _, err := compileCondition(sig.Expression); err != nil {
			return err
		}
	}
	return nil
}

// Statuses freezes authorized device definitions before one bounded runtime read.
// Results contain no source values or hidden point identities.
func (s *Service) Statuses(ctx context.Context, ids []string) ([]LiveStatus, error) {
	if len(ids) == 0 || len(ids) > 100 {
		return nil, fmt.Errorf("每次查询1至100台设备")
	}
	devices, err := s.statusDevices(ctx, ids)
	if err != nil {
		return nil, err
	}
	pointIDs := []string{}
	for _, d := range devices {
		for _, sig := range []*Signal{d.Signals.Fault, d.Signals.Running} {
			if sig != nil {
				pointIDs = append(pointIDs, sig.PointID)
			}
		}
	}
	samples := map[string]storage.Sample{}
	if len(pointIDs) > 0 && s.ports.Live != nil {
		samples, err = s.ports.Live.ReadPointsFor(ctx, pointIDs)
		if err != nil {
			return nil, err
		}
	}
	now := time.Now().UTC()
	out := make([]LiveStatus, 0, len(devices))
	for _, d := range devices {
		state, reason := evaluateSignals(d.Signals, samples)
		out = append(out, LiveStatus{d.ID, d.Revision, state, reason, now})
	}
	return out, nil
}

// The single project service owns this compact cache. Every successful register
// or photo write invalidates it; failed writes leave the previous version intact.
func (s *Service) statusDevices(ctx context.Context, ids []string) ([]Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.statusIndex == nil {
		items, err := s.load()
		if err != nil {
			return nil, err
		}
		s.statusIndex = make(map[string]Device, len(items))
		for _, d := range items {
			s.statusIndex[d.ID] = Device{ID: d.ID, Revision: d.Revision, Station: d.Station, Signals: d.Signals}
		}
	}
	out := make([]Device, 0, len(ids))
	seen := map[string]bool{}
	for _, id := range ids {
		d, ok := s.statusIndex[id]
		if !ok || !allowed(ctx, d.Station, false) {
			return nil, ErrMissing
		}
		if !seen[id] {
			out = append(out, d)
			seen[id] = true
		}
	}
	return out, nil
}

func evaluateSignals(signals Signals, values map[string]storage.Sample) (string, string) {
	if signals.Fault == nil && signals.Running == nil {
		return "unconfigured", ""
	}
	for _, sig := range []*Signal{signals.Fault, signals.Running} {
		if sig != nil {
			if _, ok := values[sig.PointID]; !ok {
				return "unknown", "unavailable"
			}
		}
	}
	evaluate := func(sig *Signal) (bool, string) {
		v, ok := values[sig.PointID]
		if !ok {
			return false, "unavailable"
		}
		if v.Quality != "good" {
			return false, "invalid_input"
		}
		var x float64
		switch n := v.Value.(type) {
		case bool:
			if n {
				x = 1
			}
		case float64:
			x = n
		case float32:
			x = float64(n)
		case int:
			x = float64(n)
		case int64:
			x = float64(n)
		default:
			return false, "invalid_input"
		}
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return false, "invalid_input"
		}
		program, err := compileCondition(sig.Expression)
		if err != nil {
			return false, "invalid_expression"
		}
		result, err := evalCondition(program, x, false, 0)
		if err != nil {
			return false, "invalid_expression"
		}
		return result.b, ""
	}
	if signals.Fault != nil {
		fault, reason := evaluate(signals.Fault)
		if reason != "" {
			return "unknown", reason
		}
		if fault {
			return "fault", ""
		}
	}
	if signals.Running == nil {
		return "unknown", "no_running_signal"
	}
	running, reason := evaluate(signals.Running)
	if reason != "" {
		return "unknown", reason
	}
	if running {
		return "running", ""
	}
	return "stopped", ""
}

// Only scalar x, finite arithmetic, comparisons and boolean operators are legal.
// There are no functions, loops, collections, indexing, I/O or implicit truthiness.
type conditionValue struct {
	n       float64
	b       bool
	boolean bool
}

func compileCondition(source string) (ast.Expr, error) {
	if len(source) == 0 || len(source) > 256 || strings.ContainsAny(source, "\n\r;") {
		return nil, fmt.Errorf("公式长度应为1至256字节")
	}
	node, err := parser.ParseExpr(source)
	if err != nil {
		return nil, fmt.Errorf("公式格式无效：使用x、比较和 && / ||")
	}
	count := 0
	ast.Inspect(node, func(n ast.Node) bool {
		if n != nil {
			count++
		}
		return true
	})
	if count > 64 {
		return nil, fmt.Errorf("公式过于复杂")
	}
	v, err := evalCondition(node, 1, true, 0)
	if err != nil || !v.boolean {
		return nil, fmt.Errorf("公式必须是简单条件，例如 x != 0 或 x >= 0.5 && x <= 100")
	}
	return node, nil
}
func evalCondition(node ast.Expr, x float64, validate bool, depth int) (conditionValue, error) {
	bad := func() (conditionValue, error) { return conditionValue{}, fmt.Errorf("无效表达式或计算结果") }
	if depth > 16 {
		return bad()
	}
	number := func(n float64) (conditionValue, error) {
		if math.IsNaN(n) || math.IsInf(n, 0) {
			return bad()
		}
		return conditionValue{n: n}, nil
	}
	boolean := func(b bool) (conditionValue, error) { return conditionValue{b: b, boolean: true}, nil }
	switch n := node.(type) {
	case *ast.ParenExpr:
		return evalCondition(n.X, x, validate, depth+1)
	case *ast.Ident:
		if n.Name == "x" {
			return number(x)
		}
		return bad()
	case *ast.BasicLit:
		if n.Kind != token.INT && n.Kind != token.FLOAT {
			return bad()
		}
		f, err := strconv.ParseFloat(n.Value, 64)
		if err != nil {
			return bad()
		}
		return number(f)
	case *ast.UnaryExpr:
		v, e := evalCondition(n.X, x, validate, depth+1)
		if e != nil {
			return bad()
		}
		if n.Op == token.NOT && v.boolean {
			return boolean(!v.b)
		}
		if !v.boolean {
			if n.Op == token.ADD {
				return number(v.n)
			}
			if n.Op == token.SUB {
				return number(-v.n)
			}
		}
		return bad()
	case *ast.BinaryExpr:
		a, e := evalCondition(n.X, x, validate, depth+1)
		if e != nil {
			return bad()
		}
		b, e := evalCondition(n.Y, x, validate, depth+1)
		if e != nil {
			return bad()
		}
		if a.boolean || b.boolean {
			if !a.boolean || !b.boolean {
				return bad()
			}
			switch n.Op {
			case token.LAND:
				return boolean(a.b && b.b)
			case token.LOR:
				return boolean(a.b || b.b)
			case token.EQL:
				return boolean(a.b == b.b)
			case token.NEQ:
				return boolean(a.b != b.b)
			}
			return bad()
		}
		switch n.Op {
		case token.ADD:
			if validate {
				return number(1)
			}
			return number(a.n + b.n)
		case token.SUB:
			if validate {
				return number(1)
			}
			return number(a.n - b.n)
		case token.MUL:
			if validate {
				return number(1)
			}
			return number(a.n * b.n)
		case token.QUO:
			if validate {
				return number(1)
			}
			if b.n == 0 {
				return bad()
			}
			return number(a.n / b.n)
		case token.GTR:
			return boolean(a.n > b.n)
		case token.GEQ:
			return boolean(a.n >= b.n)
		case token.LSS:
			return boolean(a.n < b.n)
		case token.LEQ:
			return boolean(a.n <= b.n)
		case token.EQL:
			return boolean(a.n == b.n)
		case token.NEQ:
			return boolean(a.n != b.n)
		}
		return bad()
	}
	return bad()
}
