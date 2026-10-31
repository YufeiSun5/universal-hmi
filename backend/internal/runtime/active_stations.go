package runtime

// ActiveStations returns detached owner references for deletion preflight. It
// must be called before acquiring a storage configuration transaction.
func (e *Engine) ActiveStations() map[string][]string {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := map[string][]string{}
	for _, p := range e.active {
		out[p.Station] = append(out[p.Station], p.ID)
	}
	return out
}
