package runtime

// SourceDirectory exposes only non-secret identity for explicit import mapping.
func (e *Engine) SourceDirectory() []map[string]string {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := []map[string]string{}
	for _, s := range e.sources {
		out = append(out, map[string]string{"id": s.ID, "name": s.Name})
	}
	return out
}
