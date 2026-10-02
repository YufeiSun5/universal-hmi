package server

import (
	"bytes"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"unicode/utf8"
)

const MCPSettingsPath = "/api/v1/mcp/settings"

type MCPMode string

const (
	MCPOff      MCPMode = "off"
	MCPReadOnly MCPMode = "read_only"
	MCPWrite    MCPMode = "write"
)

// SettingsHandler is mounted outside /mcp but inside the SAME authentication
// middleware. Disabling MCP must not prevent an authorized operator re-enabling
// it. This control is deliberately not an MCP tool. It creates no credentials,
// persistent configuration, listeners, or additional startup authority.
func (h *MCPHandler) SettingsHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if r.URL.Path != MCPSettingsPath {
			http.NotFound(w, r)
			return
		}
		if !h.boundaryAllowed(w, r) {
			return
		}
		principal, ok := PrincipalFromContext(r.Context())
		if !ok || (h.options.Authorize != nil && !h.options.Authorize(r, false)) {
			writeError(w, http.StatusForbidden, "permission_denied", "MCP settings require the application session")
			return
		}
		select {
		case h.settingsSlots <- struct{}{}:
			defer func() { <-h.settingsSlots }()
		default:
			w.Header().Set("Retry-After", "1")
			writeError(w, 429, "mcp_busy", "MCP settings request limit reached")
			return
		}
		canChange := principal.AllowWrite && (h.options.Authorize == nil || h.options.Authorize(r, true))
		switch r.Method {
		case http.MethodGet:
			h.mu.RLock()
			defer h.mu.RUnlock()
			h.writeSettings(w, r, canChange)
		case http.MethodPut:
			if !canChange {
				writeError(w, http.StatusForbidden, "write_forbidden", "This account cannot change MCP mode")
				return
			}
			media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if err != nil || media != "application/json" {
				writeError(w, 415, "invalid_content_type", "Settings require application/json")
				return
			}
			data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1024))
			if err != nil {
				writeError(w, 413, "request_too_large", "Settings request exceeds 1 KiB")
				return
			}
			if !utf8.Valid(data) {
				writeError(w, 400, "invalid_request", "Settings JSON must be UTF-8")
				return
			}
			value, err := mcpDecode(bytes.NewReader(data))
			if err != nil {
				writeError(w, 400, "invalid_request", "Expected one mode and current revision")
				return
			}
			object, ok := value.(map[string]any)
			if !ok || len(object) != 2 {
				writeError(w, 400, "invalid_request", "Expected mode and revision only")
				return
			}
			mode, modeOK := object["mode"].(string)
			revision, revisionOK := object["revision"].(json.Number)
			expected, revisionErr := revision.Int64()
			if !modeOK || (mode != string(MCPOff) && mode != string(MCPReadOnly) && mode != string(MCPWrite)) || !revisionOK || revisionErr != nil || expected < 1 {
				writeError(w, 400, "invalid_request", "Expected a supported mode and integer revision")
				return
			}
			if mode == string(MCPWrite) && !h.options.AllowWrite {
				writeError(w, 403, "mcp_write_disabled", "Write mode requires the server startup --mcp-write option")
				return
			}
			// Wait for admitted MCP requests to finish. Once this response succeeds,
			// no request admitted under the previous mode can still dispatch a write.
			h.mu.Lock()
			defer h.mu.Unlock()
			if uint64(expected) != h.revision {
				writeError(w, 409, "mcp_mode_changed", "MCP mode changed; refresh settings before applying again")
				return
			}
			if h.mode != MCPMode(mode) {
				h.mode = MCPMode(mode)
				h.revision++
			}
			h.writeSettings(w, r, canChange)
		default:
			w.Header().Set("Allow", "GET, PUT")
			writeError(w, 405, "method_not_allowed", "Method is not allowed")
		}
	})
}

// Caller holds h.mu. Counts are derived from the same registry and permissions
// used by tools/list, including the active process-local mode.
func (h *MCPHandler) writeSettings(w http.ResponseWriter, r *http.Request, canChange bool) {
	readCount, writeCount, available := 0, 0, 0
	for _, tool := range h.tools {
		if tool.Write {
			writeCount++
		} else {
			readCount++
		}
		if h.permitted(r, tool.Write) {
			available++
		}
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	writeJSON(w, 200, map[string]any{
		"endpoint_url": scheme + "://" + r.Host + "/mcp",
		"mode":         h.mode, "revision": h.revision, "endpoint": "/mcp", "protocol_version": MCPProtocolVersion,
		"startup_write_allowed": h.options.AllowWrite, "can_change_mode": canChange,
		"can_enable_write": canChange && h.options.AllowWrite, "effective_write_allowed": h.permitted(r, true),
		"read_tool_count": readCount, "write_tool_count": writeCount, "available_tool_count": available,
		"persistent": false,
	})
}
