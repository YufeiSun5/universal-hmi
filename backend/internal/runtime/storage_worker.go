package runtime

import (
	"context"
	"fmt"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

// StorageStats describes periodic storage only. Acceptance is not persistence.
// Counters are process-local; errors remain visible until that operation recovers.
type StorageStats struct {
	AcceptedBatches  uint64 `json:"accepted_batches"`
	CommittedBatches uint64 `json:"committed_batches"`
	FailedBatches    uint64 `json:"failed_batches"`
	RejectedBatches  uint64 `json:"rejected_batches"`
	CommittedSamples uint64 `json:"committed_samples"`
	FailedSamples    uint64 `json:"failed_samples"`
	RejectedSamples  uint64 `json:"rejected_samples"`
	DeferredScans    uint64 `json:"deferred_scans"`
	PendingBatches   int    `json:"pending_batches"`
	PendingSamples   int    `json:"pending_samples"`
}

type storageTask struct {
	operation  string
	policy     Policy
	rows       []storage.Sample
	values     map[string]string
	generation uint64
	version    string
	prune      bool
	except     []string
}

func (e *Engine) enqueueStorageLocked(task storageTask) bool {
	// Includes the in-flight batch; both jobs and sample memory are bounded.
	if e.storageStats.PendingSamples+len(task.rows) <= 100000 {
		select {
		case e.storageQueue <- task:
			e.storagePending[task.operation] = true
			e.storageStats.AcceptedBatches++
			e.storageStats.PendingBatches++
			e.storageStats.PendingSamples += len(task.rows)
			return true
		default:
		}
	}
	e.storageStats.RejectedBatches++
	e.storageStats.RejectedSamples += uint64(len(task.rows))
	e.recordStorageErrorLocked(task.operation, fmt.Errorf("storage queue full; sampling opportunity rejected, not committed"))
	return false
}

func (e *Engine) storageLoop() {
	defer close(e.storageDone)
	for task := range e.storageQueue {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		var err error
		if task.prune {
			if task.policy.Station == "" {
				err = e.Store.PruneExcept(ctx, task.policy.RetentionDays, task.except)
			} else {
				err = e.Store.PruneStation(ctx, task.policy.Station, task.policy.RetentionDays)
			}
		} else {
			err = e.Store.Append(ctx, task.rows)
		}
		cancel()
		e.mu.Lock()
		delete(e.storagePending, task.operation)
		e.storageStats.PendingBatches--
		e.storageStats.PendingSamples -= len(task.rows)
		if err != nil {
			e.storageStats.FailedBatches++
			e.storageStats.FailedSamples += uint64(len(task.rows))
		} else {
			e.storageStats.CommittedBatches++
			e.storageStats.CommittedSamples += uint64(len(task.rows))
			// An old frozen batch may finish after Apply or a policy edit. It
			// must not seed the new policy's changed-only comparison baseline.
			if !task.prune && task.generation == e.storageGeneration[task.policy.Station] && task.version == e.version {
				values := e.lastValues
				if task.policy.Station != "" {
					values = e.stationValues[task.policy.Station]
				}
				if values == nil {
					values = map[string]string{}
				}
				for id, value := range task.values {
					values[id] = value
				}
				if task.policy.Station == "" {
					e.lastValues = values
				} else {
					e.stationValues[task.policy.Station] = values
				}
			}
		}
		e.recordStorageErrorLocked(task.operation, err)
		e.mu.Unlock()
	}
}
