package runtime

import (
	"fmt"
	"reflect"
	goruntime "runtime"
	"sync"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func TestConcurrentDemoStartsPublishOneCompleteConfiguration(t *testing.T) {
	e, ps := setup(t)
	existing := point(t, ps, "user point", false)
	if _, err := e.Apply(); err != nil {
		t.Fatal(err)
	}
	if err := e.Manual(existing.ID, 7.0); err != nil {
		t.Fatal(err)
	}
	// This reader exercises the same configuration service as the startup HTTP
	// catalog request. No observation may expose an intermediate demo station.
	stopReader := make(chan struct{})
	readerDone := make(chan struct{})
	partial := make(chan int, 1)
	readerReady := make(chan struct{})
	go func() {
		defer close(readerDone)
		close(readerReady)
		for {
			select {
			case <-stopReader:
				return
			default:
			}
			count := len(ps.List())
			if count != 1 && count != 91 {
				select {
				case partial <- count:
				default:
				}
			}
			goruntime.Gosched()
		}
	}()
	<-readerReady
	start := make(chan struct{})
	results := make(chan error, 8)
	var calls sync.WaitGroup
	for i := 0; i < 8; i++ {
		calls.Add(1)
		go func() { defer calls.Done(); <-start; results <- e.Demo(true) }()
	}
	close(start)
	done := make(chan struct{})
	go func() { calls.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("concurrent demo initialization blocked")
	}
	close(stopReader)
	<-readerDone
	close(results)
	for err := range results {
		if err != nil {
			t.Fatalf("concurrent demo start failed: %v", err)
		}
	}
	select {
	case count := <-partial:
		t.Fatalf("startup catalog saw partial demo configuration: %d points", count)
	default:
	}
	definitions := ps.List()
	if len(definitions) != 91 {
		t.Fatalf("duplicate or missing demo points: %d", len(definitions))
	}
	stations := map[string]int{}
	preserved := false
	for _, p := range definitions {
		if p.ID == existing.ID {
			preserved = reflect.DeepEqual(p, existing)
		}
		if p.SourceType == "simulator" {
			stations[p.Station]++
		}
	}
	if !preserved {
		t.Fatal("user definition changed")
	}
	if len(stations) != 30 {
		t.Fatalf("demo stations=%d", len(stations))
	}
	for station, count := range stations {
		if count != 3 {
			t.Fatalf("station %s has %d points", station, count)
		}
	}
	snapshot := e.Snapshot()
	if len(snapshot["values"].([]storage.Sample)) != 91 || snapshot["demo"] != true {
		t.Fatal("complete configuration not activated")
	}
}

func TestDemoBatchValidationFailureLeavesExistingConfigurationUntouched(t *testing.T) {
	for _, kind := range []string{"identity", "capacity"} {
		t.Run(kind, func(t *testing.T) {
			e, ps := setup(t)
			if kind == "identity" {
				if _, err := ps.Create(points.CreateInput{Station: "IO-30", Name: "设定值", DataType: "FLOAT", SourceType: "manual"}); err != nil {
					t.Fatal(err)
				}
			} else {
				// Only 89 slots remain. No first 89 demo points may be committed.
				inputs := make([]points.CreateInput, points.MaxDefinitions-89)
				for i := range inputs {
					inputs[i] = points.CreateInput{Station: "User", Name: fmt.Sprintf("User %d", i), DataType: "FLOAT", SourceType: "manual"}
				}
				if _, err := ps.CreateBatch(inputs); err != nil {
					t.Fatal(err)
				}
			}
			before := ps.List()
			version, err := e.Apply()
			if err != nil {
				t.Fatal(err)
			}
			if err := e.Demo(true); err == nil {
				t.Fatalf("%s conflict accepted", kind)
			}
			after := ps.List()
			if !reflect.DeepEqual(before, after) {
				t.Fatalf("%s failure partially modified definitions (%d -> %d)", kind, len(before), len(after))
			}
			e.mu.Lock()
			defer e.mu.Unlock()
			if e.demo || e.version != version {
				t.Fatal("failed demo changed active state")
			}
		})
	}
}
