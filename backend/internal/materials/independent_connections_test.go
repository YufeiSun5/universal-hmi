package materials

import (
	"errors"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

// Separate connection pools ensure that a Go/sql single-connection limit or a
// process-local mutex cannot accidentally be the thing preventing double posts.
func independentService(t *testing.T, original *Service) *Service {
	t.Helper()
	var path, dsn string
	if original.db.PostgreSQL {
		var schema string
		if e := original.db.QueryRow("SELECT current_schema()").Scan(&schema); e != nil {
			t.Fatal(e)
		}
		if !strings.HasPrefix(schema, "materials_test_") {
			t.Fatal("not an isolated materials schema")
		}
		parsed := must(url.Parse(os.Getenv("HMI_MATERIALS_TEST_PG_DSN")))(t)
		q := parsed.Query()
		q.Set("search_path", schema)
		parsed.RawQuery = q.Encode()
		dsn = parsed.String()
	} else {
		var sequence int
		var name string
		if e := original.db.QueryRow("PRAGMA database_list").Scan(&sequence, &name, &path); e != nil {
			t.Fatal(e)
		}
		if path == "" || name != "main" {
			t.Fatal("missing isolated SQLite path")
		}
		if _, e := original.db.Exec("PRAGMA journal_mode=WAL"); e != nil {
			t.Fatal(e)
		}
		if _, e := original.db.Exec("PRAGMA busy_timeout=3000"); e != nil {
			t.Fatal(e)
		}
	}
	db := must(persistence.Open(path, dsn))(t)
	t.Cleanup(func() { db.Close() })
	if !db.PostgreSQL {
		if _, e := db.Exec("PRAGMA busy_timeout=3000"); e != nil {
			t.Fatal(e)
		}
	}
	return must(Open(db))(t)
}

func TestIndependentConnectionsCannotDoublePost(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			f := setup(t, pg)
			second := independentService(t, f.s)
			f.inbound(t, "1", Application{})
			first, other := f.outboundInput(t, "1"), f.outboundInput(t, "1")
			start := make(chan struct{})
			results := make(chan error, 2)
			var wg sync.WaitGroup
			wg.Add(2)
			go func() { defer wg.Done(); <-start; _, e := f.s.Confirm(f.ctx, "outbound", first); results <- e }()
			go func() { defer wg.Done(); <-start; _, e := second.Confirm(f.ctx, "outbound", other); results <- e }()
			close(start)
			wg.Wait()
			close(results)
			succeeded := 0
			for e := range results {
				if e == nil {
					succeeded++
				} else if !errors.Is(e, ErrConflict) && !errors.Is(e, ErrStock) {
					t.Fatal(e)
				}
			}
			if succeeded != 1 {
				t.Fatalf("expected one committed outbound, got %d", succeeded)
			}
			if balance := f.stock(t, f.normal.ID); balance.Quantity != "0" {
				t.Fatalf("balance %+v", balance)
			}
			docs := must(second.Documents(f.ctx, "outbound", Filter{}))(t)
			if docs.Total != 1 {
				t.Fatalf("outbound count %d", docs.Total)
			}
			out := docs.Items[0]
			request := DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "1", TargetCategoryID: f.scrap.ID}}}
			// Simulate a committed response lost by the first process, followed by a
			// retry through a different process/connection pool.
			posted := must(f.s.Confirm(f.ctx, "return", request))(t)
			replay := must(second.Confirm(f.ctx, "return", request))(t)
			if posted.ID != replay.ID {
				t.Fatal("cross-pool retry duplicated return")
			}
			if balance := f.stock(t, f.scrap.ID); balance.Quantity != "1" || balance.TotalQuantity != "1" {
				t.Fatalf("return balance %+v", balance)
			}
			history := must(second.Document(f.ctx, out.ID, Filter{}))(t)
			if history.Returns.Total != 1 || history.Document.Status != "returned" {
				t.Fatal("return trace duplicated")
			}
		})
	}
}
