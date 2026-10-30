package runtime

import (
	"context"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func TestKIOConstantConfirmationExpiresAndPropagatesToVirtual(t *testing.T) {
	e, ps := policyFixture(t)
	p, err := ps.Create(points.CreateInput{Station: "A", Name: "constant", DataType: "FLOAT", SourceType: "mqtt", SourceID: "s", SourcePath: "x", StaleMS: 5000})
	if err != nil {
		t.Fatal(err)
	}
	v, err := ps.Create(points.CreateInput{Station: "B", Name: "derived", DataType: "FLOAT", SourceType: "virtual", Expression: "v[0]*2", Inputs: []string{p.ID}, StaleMS: 5000})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.Apply(); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	source := now.Add(-157 * time.Second)
	e.mu.Lock()
	e.sources = []acquisition.Source{{ID: "s", Protocol: "kingio"}}
	e.sourceState["s"] = "connected"
	e.ingest(p, 7.0, "good", source, now, now)
	e.evaluate(now)
	if !e.good(p.ID, now) || !e.good(v.ID, now) || e.live[v.ID].Value != 14.0 || !e.live[v.ID].SourceTime.Equal(source) {
		e.mu.Unlock()
		t.Fatal("constant source timestamp invalidated confirmed data")
	}
	firstReceive := e.live[v.ID].ReceivedTime
	e.evaluate(now.Add(time.Second))
	if !e.live[v.ID].ReceivedTime.Equal(firstReceive) {
		e.mu.Unlock()
		t.Fatal("idle evaluation manufactured received time")
	}
	e.evaluate(now.Add(6 * time.Second))
	if e.good(p.ID, now.Add(6*time.Second)) || e.good(v.ID, now.Add(6*time.Second)) {
		e.mu.Unlock()
		t.Fatal("broker connected kept unconfirmed values fresh")
	}
	e.ingest(p, 7.0, "good", source, now.Add(7*time.Second), now.Add(7*time.Second))
	e.evaluate(now.Add(7 * time.Second))
	if !e.good(v.ID, now.Add(7*time.Second)) {
		e.mu.Unlock()
		t.Fatal("unchanged full reply did not restore derived value")
	}
	// Retained data cannot be used as a new quality confirmation.
	e.ingest(p, 7.0, "good", source, now.Add(8*time.Second), time.Time{})
	e.evaluate(now.Add(8 * time.Second))
	if e.good(p.ID, now.Add(8*time.Second)) || e.good(v.ID, now.Add(8*time.Second)) {
		e.mu.Unlock()
		t.Fatal("retained payload refreshed freshness")
	}
	e.ingest(p, 7.0, "bad", source, now, now)
	e.evaluate(now)
	if e.good(v.ID, now) {
		e.mu.Unlock()
		t.Fatal("bad confirmed input became valid")
	}
	e.ingest(p, 7.0, "good", source, now, now)
	e.sourceState["s"] = "disconnected"
	e.evaluate(now)
	if e.good(v.ID, now) {
		e.mu.Unlock()
		t.Fatal("disconnection did not invalidate derived value")
	}
	e.mu.Unlock()
	data, err := e.SubscriptionSnapshot(context.Background(), []string{p.ID, v.ID})
	if err != nil || data == nil {
		t.Fatal(err)
	}
}

func TestOldConnectionGenerationCannotRepopulateLiveValues(t *testing.T) {
	e, ps := setup(t)
	p, err := ps.Create(points.CreateInput{Station: "A", Name: "input", SourceType: "mqtt", SourceID: "s", SourcePath: "x", DataType: "FLOAT"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.Apply(); err != nil {
		t.Fatal(err)
	}
	e.mu.Lock()
	e.connectionGeneration["s"] = 2
	e.mu.Unlock()
	now := time.Now()
	e.Submit([]acquisition.Raw{{SourceID: "s", Path: "x", Value: 9.0, Quality: "good", Time: now, Generation: 1}})
	deadline := time.Now().Add(time.Second)
	for e.processed.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	e.mu.Lock()
	_, exists := e.live[p.ID]
	e.mu.Unlock()
	if exists || e.processed.Load() != 1 {
		t.Fatal("old queued connection data entered current runtime")
	}
}
