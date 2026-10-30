package server

import (
	"context"
	"net/http"
	"strings"
	"sync"
)

// One process-wide boundary also covers separately constructed local/public
// handlers. Nested adapters and MCP's HTTP dispatch retain the context marker.
var configurationWrites sync.Mutex

type configurationWriteKey struct{}

func configurationMutationGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet || r.Method == http.MethodHead || r.Method == http.MethodOptions || !strings.HasPrefix(r.URL.Path, "/api/v1/") || r.Context().Value(configurationWriteKey{}) != nil {
			next.ServeHTTP(w, r)
			return
		}
		configurationWrites.Lock()
		defer configurationWrites.Unlock()
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), configurationWriteKey{}, true)))
	})
}
