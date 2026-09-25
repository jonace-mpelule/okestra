package agent

import (
	"encoding/json"
	"sort"
	"sync"
	"time"

	"github.com/jonace-mpelule/okestra/internal/protocol"
)

const (
	maxCachedOperationMessages = 256
	maxRememberedOperations    = 64
)

type OperationBroker struct {
	mu    sync.RWMutex
	ops   map[string]*protocol.OperationStatus
	subs  map[string]map[chan []byte]struct{}
	cache map[string][][]byte
}

func NewOperationBroker() *OperationBroker {
	return &OperationBroker{
		ops:   make(map[string]*protocol.OperationStatus),
		subs:  make(map[string]map[chan []byte]struct{}),
		cache: make(map[string][][]byte),
	}
}

func (b *OperationBroker) Start(id, typ string) {
	now := time.Now().UTC()
	b.mu.Lock()
	defer b.mu.Unlock()
	b.ops[id] = &protocol.OperationStatus{
		ID:        id,
		Type:      typ,
		State:     "running",
		CreatedAt: now,
		UpdatedAt: now,
	}
	b.pruneLocked()
}

func (b *OperationBroker) Update(id, state, msg string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	op, ok := b.ops[id]
	if !ok {
		return
	}
	op.State = state
	op.Message = msg
	op.UpdatedAt = time.Now().UTC()
}

func (b *OperationBroker) Publish(id string, env protocol.StreamEnvelope) {
	data, _ := json.Marshal(env)
	b.mu.Lock()
	defer b.mu.Unlock()
	b.cache[id] = append(b.cache[id], data)
	if len(b.cache[id]) > maxCachedOperationMessages {
		b.cache[id] = append([][]byte(nil), b.cache[id][len(b.cache[id])-maxCachedOperationMessages:]...)
	}
	for ch := range b.subs[id] {
		select {
		case ch <- data:
		default:
			if env.Type == "eof" || env.Type == "error" {
				select {
				case <-ch:
				default:
				}
				ch <- data
			}
		}
	}
}

func (b *OperationBroker) Subscribe(id string) (<-chan []byte, func()) {
	b.mu.Lock()
	cached := append([][]byte(nil), b.cache[id]...)
	ch := make(chan []byte, len(cached)+32)
	for _, item := range cached {
		ch <- item
	}
	if b.subs[id] == nil {
		b.subs[id] = make(map[chan []byte]struct{})
	}
	b.subs[id][ch] = struct{}{}
	b.mu.Unlock()

	var once sync.Once
	cancel := func() {
		once.Do(func() {
			b.mu.Lock()
			defer b.mu.Unlock()
			delete(b.subs[id], ch)
			close(ch)
		})
	}
	return ch, cancel
}

func (b *OperationBroker) Snapshot() []protocol.OperationStatus {
	b.mu.RLock()
	defer b.mu.RUnlock()
	out := make([]protocol.OperationStatus, 0, len(b.ops))
	for _, op := range b.ops {
		if op.State == "running" {
			out = append(out, *op)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}

func (b *OperationBroker) pruneLocked() {
	if len(b.ops) <= maxRememberedOperations {
		return
	}
	type candidate struct {
		id string
		at time.Time
	}
	var completed []candidate
	for id, op := range b.ops {
		if op.State != "running" {
			completed = append(completed, candidate{id: id, at: op.UpdatedAt})
		}
	}
	sort.Slice(completed, func(i, j int) bool { return completed[i].at.Before(completed[j].at) })
	for _, item := range completed {
		if len(b.ops) <= maxRememberedOperations {
			break
		}
		delete(b.ops, item.id)
		delete(b.cache, item.id)
		delete(b.subs, item.id)
	}
}
