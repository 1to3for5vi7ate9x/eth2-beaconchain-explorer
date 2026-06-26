package exporter

import (
	"sync"
	"time"
)

// bigtableWriteJob is one Bigtable write captured as a closure, so each call site
// can enqueue exactly the work it would otherwise have run inline.
type bigtableWriteJob struct {
	desc string
	run  func() error
}

var (
	bigtableWriteQueue chan bigtableWriteJob
	bigtableWriteOnce  sync.Once
)

// enqueueBigtableWrite routes a Bigtable write to a single, ordered, background
// worker. Every Bigtable write the slot exporter performs goes through here, so the
// postgres block/epoch transaction can commit immediately instead of waiting on
// ~110s/epoch of Bigtable I/O — that is what lets "most recent blocks" track the
// chain head live while validator history/charts trail slightly behind.
//
// The worker is strictly FIFO and single-threaded, so writes are applied in the
// exact same order as the old inline path (an epoch's duty assignments before the
// per-slot inclusions enqueued afterwards). Preserving order preserves the existing
// (versioned-cell) attestation semantics — no new races are introduced.
//
// The queue is bounded: if the worker ever falls behind (e.g. a catch-up burst),
// enqueue blocks and the exporter slows to the worker's rate rather than dropping
// writes or growing memory without limit.
func enqueueBigtableWrite(desc string, run func() error) {
	bigtableWriteOnce.Do(func() {
		bigtableWriteQueue = make(chan bigtableWriteJob, 128)
		go bigtableWriteWorker()
	})
	bigtableWriteQueue <- bigtableWriteJob{desc: desc, run: run}
}

// bigtableWriteWorker drains the queue in order, retrying each write (the Save*
// calls are idempotent upserts) before giving up loudly. Because the block has
// already been committed by the time a write runs, a permanent failure leaves that
// batch of validator data missing until a re-export — hence the generous retry.
func bigtableWriteWorker() {
	for job := range bigtableWriteQueue {
		var err error
		for attempt := 1; attempt <= 8; attempt++ {
			if err = job.run(); err == nil {
				break
			}
			logger.Warnf("async bigtable write %q failed (attempt %d/8): %v", job.desc, attempt, err)
			time.Sleep(time.Second * time.Duration(attempt))
		}
		if err != nil {
			logger.Errorf("async bigtable write %q GAVE UP after 8 attempts — validator data for this batch may be missing until re-export: %v", job.desc, err)
		}
	}
}
