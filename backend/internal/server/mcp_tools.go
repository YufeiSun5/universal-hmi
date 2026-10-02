package server

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/url"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/analysis"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
)

// MCPToolInfo is an auditable transport inventory, not a general HTTP proxy.
// Every supported business API operation has an explicit entry here.
type MCPToolInfo struct {
	Name   string `json:"name"`
	Method string `json:"method"`
	Path   string `json:"path"`
	Write  bool   `json:"write"`
}
type mcpTool struct {
	MCPToolInfo
	description string
	schema      *mcpSchema
	bodyKey     string
	query       []string
	upload      bool
	download    bool
}

func MCPToolInventory() []MCPToolInfo {
	tools := mcpTools()
	result := make([]MCPToolInfo, 0, len(tools))
	for _, tool := range tools {
		result = append(result, tool.MCPToolInfo)
	}
	return result
}
func (t mcpTool) definition() map[string]any {
	return map[string]any{"name": t.Name, "description": t.description, "inputSchema": t.schema,
		"annotations": map[string]any{"readOnlyHint": !t.Write, "destructiveHint": t.Write, "openWorldHint": t.Write}}
}
func mcpTools() []mcpTool {
	empty := mcpObject(map[string]*mcpSchema{})
	id := mcpString(256)
	id.MinLength = 1
	idOnly := mcpObject(map[string]*mcpSchema{"id": id}, "id")
	station := mcpString(128)
	stationOnly := mcpObject(map[string]*mcpSchema{"station": station})
	point := mcpTyped(points.CreateInput{}, "station", "name", "data_type", "source_type")
	point.Properties["station"] = station
	point.Properties["name"] = mcpString(256)
	point.Properties["inputs"] = mcpArray(mcpString(256), 0, 64)
	source := mcpTyped(acquisition.Source{}, "id", "name", "broker", "topic", "protocol")
	source.Properties["protocol"] = mcpEnum("generic", "kep", "kingio")
	policy := mcpTyped(rt.Policy{}, "enabled", "interval_ms", "retention_days")
	policy.Properties["interval_ms"] = mcpInt(200, 3600000)
	policy.Properties["retention_days"] = mcpInt(1, 3650)
	policy.Properties["station"] = station
	condition := mcpTyped(rt.Condition{}, "point_id", "op", "value")
	condition.Properties["op"] = mcpEnum(">", ">=", "<", "<=", "==", "!=")
	action := &mcpSchema{OneOf: []*mcpSchema{
		mcpObject(map[string]*mcpSchema{"type": mcpEnum("write"), "point_id": id, "value": mcpNumber()}, "type", "point_id", "value"),
		mcpObject(map[string]*mcpSchema{"type": mcpEnum("snapshot", "storage_start", "storage_stop"), "point_id": mcpString(256), "value": mcpNumber()}, "type"),
	}}
	rule := mcpTyped(rt.Rule{}, "id", "name", "enabled", "logic", "conditions", "hold_ms", "cooldown_ms", "trigger", "actions")
	rule.Properties["station"] = station
	rule.Properties["logic"] = mcpEnum("and", "or")
	rule.Properties["conditions"] = mcpArray(condition, 1, 32)
	rule.Properties["actions"] = mcpArray(action, 1, 16)
	rule.Properties["hold_ms"] = mcpInt(0, 3600000)
	rule.Properties["cooldown_ms"] = mcpInt(200, 86400000)
	rule.Properties["trigger"] = mcpEnum("rising", "periodic", "recovery")
	mapping := mcpTyped(analysis.Mapping{}, "session_id", "sheet", "time_column", "value_column", "header", "station", "name")
	mapping.Properties["time_column"] = mcpInt(0, 99)
	mapping.Properties["value_column"] = mcpInt(0, 99)
	mapping.Properties["station"] = station
	filterProperties := map[string]*mcpSchema{
		"point_id": mcpString(256), "point_ids": mcpString(1541), "station": station, "quality": mcpString(64),
		"from": mcpInt(0, 9007199254740991), "to": mcpInt(0, 9007199254740991),
		"before": mcpInt(-1, 9007199254740991), "after": mcpInt(0, 9007199254740991),
		"limit": mcpInt(1, 5000), "offset": mcpInt(0, 9007199254740991), "min": mcpNumber(), "max": mcpNumber(),
	}
	filterKeys := []string{"point_id", "point_ids", "station", "quality", "from", "to", "before", "after", "limit", "offset", "min", "max"}
	exportProperties := map[string]*mcpSchema{}
	for key, schema := range filterProperties {
		exportProperties[key] = schema
	}
	exportProperties["format"] = mcpEnum("csv", "xlsx")
	tools := []mcpTool{}
	add := func(name, method, path, description string, write bool, schema *mcpSchema, bodyKey string, query ...string) {
		tools = append(tools, mcpTool{MCPToolInfo: MCPToolInfo{name, method, path, write}, description: description, schema: schema, bodyKey: bodyKey, query: query})
	}
	add("health_get", "GET", "/health", "Read service health and supported capabilities.", false, empty, "")
	add("points_list", "GET", "/api/v1/points", "List saved point definitions, including scaling and offsets. Saved definitions are separate from the active runtime version.", false, empty, "")
	add("points_create", "POST", "/api/v1/points", "Save one point definition with scaling, offset, write target or bounded virtual expression. Call configuration_apply separately to activate it.", true, point, "$")
	add("points_update", "PUT", "/api/v1/points/{id}", "Replace a saved point definition, including scale_factor and offset. Does not activate it or rewrite frozen history.", true, mcpObject(map[string]*mcpSchema{"id": id, "point": point}, "id", "point"), "point")
	add("points_delete", "DELETE", "/api/v1/points/{id}", "Delete a saved point definition. Apply configuration separately; historical samples retain their original semantics.", true, idOnly, "")
	add("points_create_batch", "POST", "/api/v1/points/batch", "Validate and atomically save up to 20000 point definitions. Does not activate the saved configuration.", true, mcpObject(map[string]*mcpSchema{"items": mcpArray(point, 1, points.MaxDefinitions)}, "items"), "$")
	add("configuration_apply", "POST", "/api/v1/apply", "Validate saved points and virtual dependencies, then activate a new runtime version. Does not connect sources.", true, empty, "")
	add("runtime_get", "GET", "/api/v1/runtime", "Read active configuration/version, normalized samples, source states, rules, storage state and bounded queue diagnostics.", false, empty, "")
	add("point_sample", "POST", "/api/v1/points/{id}/sample", "Supply a manual point raw sample through the same runtime conversion and quality pipeline as HTTP.", true, mcpObject(map[string]*mcpSchema{"id": id, "sample": mcpObject(map[string]*mcpSchema{"value": {OneOf: []*mcpSchema{mcpNumber(), {Type: "boolean"}, mcpString(4096)}}}, "value")}, "id", "sample"), "sample")
	add("point_write_capability", "GET", "/api/v1/points/{id}/write-capability", "Check supported physical numeric writes, engineering range, encoding and rejection reasons before requesting control.", false, idOnly, "")
	add("point_write", "POST", "/api/v1/write", "Request a controlled engineering-value write using an explicit command ID and active version. Reuse the same ID to reconcile; never automatically retry unknown outcomes. Publication, ACK and readback are separate states.", true, mcpObject(map[string]*mcpSchema{"command_id": mcpString(128), "point_id": id, "value": mcpNumber(), "version": mcpString(256)}, "command_id", "point_id", "value", "version"), "$")
	add("command_get", "GET", "/api/v1/commands/{id}", "Reconcile one command's publication, device acknowledgement and fresh physical readback without replaying it.", false, idOnly, "")
	add("sources_save", "PUT", "/api/v1/sources", "Replace configured MQTT sources (max 32). Does not connect automatically. Credentials are not accepted in these source DTOs.", true, mcpObject(map[string]*mcpSchema{"items": mcpArray(source, 0, 32)}, "items"), "$")
	add("source_connect", "POST", "/api/v1/sources/{id}/connect", "Explicitly connect an already configured source. This can contact the configured broker; use only authorized test or deployment sources.", true, idOnly, "")
	add("source_disconnect", "POST", "/api/v1/sources/{id}/disconnect", "Disconnect one configured source; quality will reflect loss of fresh data.", true, idOnly, "")
	add("storage_get", "GET", "/api/v1/storage", "Read the selected station's independent storage policy; omitted station selects global scope.", false, stationOnly, "", "station")
	add("storage_save", "PUT", "/api/v1/storage", "Save independent storage cadence, changed-only mode, retention and selected points. Enabling storage is independent of UI or a detection session.", true, mcpObject(map[string]*mcpSchema{"station": station, "policy": policy}, "policy"), "policy", "station")
	add("storage_snapshot", "POST", "/api/v1/snapshot", "Persist a one-time snapshot in the explicit station or global scope, preserving source/receive timestamps and active scaling semantics.", true, stationOnly, "", "station")
	add("history_query", "GET", "/api/v1/history", "Query bounded frozen history with station/point/time/value/quality filters and whole-filter statistics. Preserve returned boundary in before for consistent subsequent pages and exports.", false, mcpObject(filterProperties), "", filterKeys...)
	seriesProperties := map[string]*mcpSchema{}
	seriesKeys := []string{"point_id", "point_ids", "station", "quality", "from", "to", "before", "after", "min", "max", "max_points"}
	for _, key := range seriesKeys {
		if value, ok := filterProperties[key]; ok {
			seriesProperties[key] = value
		}
	}
	seriesProperties["max_points"] = mcpInt(20, 600)
	add("history_series", "GET", "/api/v1/history/series", "Read bounded whole-range history curves and complete frozen-unit/version statistics. Select 1..6 point IDs via point_ids (comma-separated) or point_id, never both. Preserve before/boundary for a stable view; max_points is bounded to 20..600 per point. Gaps and quality changes remain explicit.", false, mcpObject(seriesProperties), "", seriesKeys...)
	add("history_catalog", "GET", "/api/v1/history/catalog", "List historical point/station identities, including imported data and earlier station membership, with a bounded limit and truncation indicator.", false, mcpObject(map[string]*mcpSchema{"station": station, "limit": mcpInt(1, 20000)}), "", "station", "limit")
	add("rules_save", "PUT", "/api/v1/rules", "Replace up to 200 declarative rules. Each has up to 32 AND/OR conditions and 16 controlled write/snapshot/storage actions; enabled rules can execute. No arbitrary script, shell, database or filesystem access. Multi-actions can partially succeed; inspect executions.", true, mcpObject(map[string]*mcpSchema{"items": mcpArray(rule, 0, 200)}, "items"), "$")
	add("rule_preview", "POST", "/api/v1/rules/preview", "Validate and evaluate a declarative rule against current runtime samples without saving, enabling or executing any action. Missing/bad/stale inputs remain unknown.", false, rule, "$")
	add("executions_list", "GET", "/api/v1/executions", "Read bounded rule execution records and per-step results, including partial failures.", false, empty, "")
	add("demo_set", "POST", "/api/v1/demo", "Explicitly start or stop the isolated 30-station simulator. Starting may create demo definitions and change runtime state.", true, mcpObject(map[string]*mcpSchema{"enabled": {Type: "boolean"}}, "enabled"), "$")
	add("import_upload", "POST", "/api/v1/import/upload", "Upload CSV/XLSX bytes as strict base64 (max 8384512 decoded bytes). Returns an expiring session and sheet previews. This only stages data; map/preview and commit separately. Never reads a caller-supplied path.", true, mcpObject(map[string]*mcpSchema{"filename": mcpString(256), "data_base64": mcpString(base64.StdEncoding.EncodedLen(MaxMCPUploadBytes))}, "filename", "data_base64"), "")
	tools[len(tools)-1].upload = true
	add("import_preview", "POST", "/api/v1/import/preview", "Preview and validate a staged CSV/XLSX sheet mapping without storing historical samples. Column indexes are zero-based.", false, mapping, "$")
	add("import_commit", "POST", "/api/v1/import/commit", "Validate and idempotently commit a staged CSV/XLSX mapping to frozen history. Invalid rows block the commit; it does not create acquisition points.", true, mapping, "$")
	add("export_create", "POST", "/api/v1/export", "Queue a bounded CSV/XLSX export using the exact history filters and frozen before boundary. Queueing is not file completion; poll jobs_list then export_download.", true, mcpObject(exportProperties, "format"), "", append(filterKeys, "format")...)
	add("jobs_list", "GET", "/api/v1/jobs", "List up to 64 export jobs and their queued/running/completed/failed/cancelled states.", false, empty, "")
	add("job_cancel", "POST", "/api/v1/jobs/{id}/cancel", "Request cancellation of an export job; inspect its state to distinguish queued cancellation from completion.", true, idOnly, "")
	add("job_delete", "DELETE", "/api/v1/jobs/{id}", "Remove one export job and its generated file using the existing file-job service.", true, idOnly, "")
	add("export_download", "GET", "/api/v1/jobs/{id}/file", "Read up to 1 MiB from a completed export as base64. Start offset=0 and follow next_offset until eof; only generated job files are accessible.", false, mcpObject(map[string]*mcpSchema{"id": id, "offset": mcpInt(0, 9007199254740991), "max_bytes": mcpInt(1, MaxMCPDownloadBytes)}, "id"), "")
	tools[len(tools)-1].download = true
	return tools
}

func (t mcpTool) request(parent *http.Request, args map[string]any) (*http.Request, error) {
	path := t.Path
	if strings.Contains(path, "{id}") {
		id := args["id"].(string)
		if id == "." || id == ".." || strings.ContainsRune(id, 0) {
			return nil, fmt.Errorf("invalid identity")
		}
		path = strings.Replace(path, "{id}", url.PathEscape(id), 1)
	}
	query := url.Values{}
	for _, key := range t.query {
		if value, ok := args[key]; ok {
			query.Set(key, mcpQueryValue(value))
		}
	}
	if len(query) > 0 {
		path += "?" + query.Encode()
	}
	var body []byte
	contentType := "application/json"
	if t.upload {
		filename := args["filename"].(string)
		if filename == "" || strings.ContainsAny(filename, "/\\\r\n\x00") || (!strings.HasSuffix(strings.ToLower(filename), ".csv") && !strings.HasSuffix(strings.ToLower(filename), ".xlsx")) {
			return nil, fmt.Errorf("filename must be a simple .csv or .xlsx name")
		}
		encoded := args["data_base64"].(string)
		if strings.ContainsAny(encoded, "\r\n") {
			return nil, fmt.Errorf("data_base64 must use unbroken standard base64")
		}
		data, err := base64.StdEncoding.Strict().DecodeString(encoded)
		if err != nil || len(data) == 0 || len(data) > MaxMCPUploadBytes {
			return nil, fmt.Errorf("invalid base64 or decoded upload size")
		}
		var buffer bytes.Buffer
		writer := multipart.NewWriter(&buffer)
		part, err := writer.CreateFormFile("file", filename)
		if err != nil {
			return nil, err
		}
		if _, err = part.Write(data); err != nil {
			return nil, err
		}
		if err = writer.Close(); err != nil {
			return nil, err
		}
		body = buffer.Bytes()
		contentType = writer.FormDataContentType()
	} else if t.bodyKey != "" {
		value := any(args)
		if t.bodyKey != "$" {
			value = args[t.bodyKey]
		}
		var err error
		body, err = json.Marshal(value)
		if err != nil {
			return nil, err
		}
	}
	request, err := http.NewRequestWithContext(parent.Context(), t.Method, path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Host = parent.Host
	request.TLS = parent.TLS // preserve the verified HTTPS origin for shared HTTP guards
	request.RemoteAddr = parent.RemoteAddr
	request.Header = parent.Header.Clone()
	// Never forward client-controlled range or conditional headers into the
	// internally dispatched operation, or JSON-RPC headers as API content headers.
	for _, key := range []string{"Range", "If-Range", "If-Modified-Since", "If-Unmodified-Since", "If-Match", "If-None-Match", "Content-Length", "Content-Type", "Accept", "MCP-Protocol-Version", "MCP-Session-Id"} {
		request.Header.Del(key)
	}
	request.Header.Set("Content-Type", contentType)
	request.Header.Set("Accept", "application/json")
	if t.download {
		size := mcpInteger(args["max_bytes"])
		if size == 0 {
			size = MaxMCPDownloadBytes
		}
		offset := mcpInteger(args["offset"])
		request.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", offset, offset+size-1))
	}
	return request, nil
}
