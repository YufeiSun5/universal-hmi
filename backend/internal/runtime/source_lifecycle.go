package runtime

import (
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
)

// Each logical source has one supervisor, even when multiple clients open the UI.
type sourceRun struct {
	stop  chan struct{}
	done  chan struct{}
	first chan error
}

func standbySource(s acquisition.Source) acquisition.Source {
	b := s.Standby
	s.Broker = b.Broker
	if b.Topic != "" {
		s.Topic = b.Topic
	} else if b.ClientID != "" && s.Topic == acquisition.KIODataTopic(s.ClientID) {
		s.Topic = acquisition.KIODataTopic(b.ClientID)
	}
	if b.ClientID != "" {
		s.ClientID = b.ClientID
	}
	return s
}

// A standby filter must carry the same variable topic levels as the primary.
func wildcardShape(filter string) (string, bool) {
	var shape string
	levels := strings.Split(filter, "/")
	for i, v := range levels {
		switch v {
		case "+":
			shape += "+"
		case "#":
			if i != len(levels)-1 {
				return "", false
			}
			shape += "#"
		default:
			if strings.ContainsAny(v, "#+\x00") {
				return "", false
			}
		}
	}
	return shape, true
}
func validateStandby(s acquisition.Source) error {
	if s.Standby == nil {
		return nil
	}
	b := standbySource(s)
	u, err := url.Parse(b.Broker)
	main, _ := url.Parse(s.Broker)
	if err != nil || u.Host == "" || (u.Scheme != "tcp" && u.Scheme != "ssl") || u.User != nil || strings.EqualFold(main.Host, u.Host) || len(b.ClientID) > 128 {
		return fmt.Errorf("invalid or duplicate standby broker")
	}
	a, valid := wildcardShape(s.Topic)
	other, ok := wildcardShape(b.Topic)
	if !valid || !ok || a != other {
		return fmt.Errorf("primary and standby topic wildcards must match")
	}
	return nil
}

// Reconstruct the logical primary topic using captures from the standby filter.
func logicalTopic(primary, standby, actual string) string {
	if primary == standby {
		return actual
	}
	parts := strings.Split(actual, "/")
	var captures [][]string
	for i, v := range strings.Split(standby, "/") {
		if v == "#" {
			if i > len(parts) {
				return actual
			}
			captures = append(captures, parts[i:])
			break
		}
		if v == "+" {
			if i >= len(parts) {
				return actual
			}
			captures = append(captures, parts[i:i+1])
		}
	}
	var out []string
	for _, v := range strings.Split(primary, "/") {
		if v == "+" || v == "#" {
			if len(captures) == 0 {
				return actual
			}
			out = append(out, captures[0]...)
			captures = captures[1:]
		} else {
			out = append(out, v)
		}
	}
	return strings.Join(out, "/")
}

func (e *Engine) StartSavedSources() {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range e.sources {
		if !s.ManualStart {
			e.startSourceLocked(s)
		}
	}
}
func (e *Engine) startSourceLocked(s acquisition.Source) *sourceRun {
	select {
	case <-e.stop:
		return nil
	default:
	}
	if e.sourceRuns[s.ID] != nil {
		return nil
	}
	r := &sourceRun{make(chan struct{}), make(chan struct{}), make(chan error, 1)}
	e.sourceRuns[s.ID] = r
	e.sourceState[s.ID] = "connecting"
	e.sourceWorkers.Add(1)
	go e.manageSource(s, r)
	return r
}

func (e *Engine) Connect(id string) error {
	e.mu.Lock()
	for _, s := range e.sources {
		if s.ID == id {
			r := e.startSourceLocked(s)
			e.mu.Unlock()
			if r == nil {
				return fmt.Errorf("source already running or shutting down")
			}
			return <-r.first
		}
	}
	e.mu.Unlock()
	return fmt.Errorf("source not found")
}
func (e *Engine) Disconnect(id string) {
	e.mu.Lock()
	r := e.sourceRuns[id]
	if r != nil {
		select {
		case <-r.stop:
		default:
			close(r.stop)
		}
	}
	e.invalidateSourceLocked(id)
	e.sourceState[id] = "disconnected"
	e.mu.Unlock()
	if r != nil {
		<-r.done
	}
}
func (e *Engine) invalidateSourceLocked(id string) {
	e.connectionGeneration[id]++
	delete(e.connections, id)
	delete(e.standbyActive, id)
	e.clearDiscoveryLocked(id)
}

func (e *Engine) clearSourceSamplesLocked(id string) {
	for _, p := range e.active {
		if p.SourceType == "mqtt" && p.SourceID == id {
			delete(e.live, p.ID)
			delete(e.confirmed, p.ID)
		}
	}
}

type activeEndpoint struct {
	connection *acquisition.Connection
	lost       chan struct{}
	standby    bool
}

func (e *Engine) openEndpoint(s acquisition.Source, r *sourceRun, standby bool) (*activeEndpoint, error) {
	endpoint := s
	if standby {
		endpoint = standbySource(s)
	}
	gate := make(chan struct{})
	lost := make(chan struct{}, 1)
	var generation uint64
	c, err := acquisition.ConnectWithOptions(endpoint, acquisition.ConnectionOptions{Activation: gate}, func(rows []acquisition.Raw) {
		select {
		case <-gate:
		default:
			return
		}
		if standby && endpoint.Topic != s.Topic {
			// One decoder batch originates from one MQTT message.
			if len(rows) > 0 {
				topic := logicalTopic(s.Topic, endpoint.Topic, rows[0].Topic)
				for i := range rows {
					rows[i].Topic = topic
				}
			}
		}
		e.receiveSource(s.ID, generation, rows)
	}, func(state string) {
		if state != "connected" {
			select {
			case lost <- struct{}{}:
			default:
			}
			e.mu.Lock()
			select {
			case <-gate:
				if e.connectionGeneration[s.ID] == generation {
					e.sourceState[s.ID] = state
				}
			default:
			}
			e.mu.Unlock()
		}
	})
	if err != nil {
		return nil, err
	}
	e.mu.Lock()
	select {
	case <-r.stop:
		err = fmt.Errorf("connection cancelled")
	case <-e.stop:
		err = fmt.Errorf("shutting down")
	case <-lost:
		err = fmt.Errorf("connection lost")
	default:
		e.invalidateSourceLocked(s.ID)
		e.clearSourceSamplesLocked(s.ID)
		generation = e.connectionGeneration[s.ID]
		e.connections[s.ID] = c
		e.sourceState[s.ID] = "connected"
		e.standbyActive[s.ID] = standby
		close(gate)
	}
	e.mu.Unlock()
	if err != nil {
		c.Close()
		return nil, err
	}
	return &activeEndpoint{c, lost, standby}, nil
}

func (e *Engine) manageSource(s acquisition.Source, r *sourceRun) {
	var active *activeEndpoint
	first := true
	defer func() {
		if active != nil {
			active.connection.Close()
		}
		e.mu.Lock()
		e.invalidateSourceLocked(s.ID)
		e.sourceState[s.ID] = "disconnected"
		delete(e.sourceRuns, s.ID)
		e.mu.Unlock()
		if first {
			r.first <- fmt.Errorf("connection cancelled")
		}
		close(r.done)
		e.sourceWorkers.Done()
	}()
	for {
		select {
		case <-r.stop:
			return
		case <-e.stop:
			return
		default:
		}
		if active == nil {
			var err error
			active, err = e.openEndpoint(s, r, false)
			if err != nil && s.Standby != nil {
				select {
				case <-r.stop:
					return
				case <-e.stop:
					return
				default:
				}
				active, err = e.openEndpoint(s, r, true)
			}
			if first {
				r.first <- err
				first = false
			}
			if err != nil {
				e.mu.Lock()
				e.sourceState[s.ID] = "failed: " + err.Error()
				e.mu.Unlock()
				select {
				case <-r.stop:
					return
				case <-e.stop:
					return
				case <-time.After(5 * time.Second):
				}
				continue
			}
		}
		var probe <-chan time.Time
		if active.standby {
			probe = time.After(10 * time.Second)
		}
		select {
		case <-r.stop:
			return
		case <-e.stop:
			return
		case <-active.lost:
			e.mu.Lock()
			e.invalidateSourceLocked(s.ID)
			e.sourceState[s.ID] = "connecting"
			e.mu.Unlock()
			active.connection.Close()
			active = nil
		case <-probe:
			primary, err := e.openEndpoint(s, r, false)
			if err == nil {
				active.connection.Close()
				active = primary
			}
		}
	}
}
