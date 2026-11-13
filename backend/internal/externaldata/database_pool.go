package externaldata

import (
	"context"
	"database/sql"
	"fmt"
)

// A source revision owns its pool. Retired pools finish existing requests before
// closing; new requests never borrow credentials from a previous revision.
type databaseLease struct {
	db      *sql.DB
	refs    int
	retired bool
	source  string
}

func (s *Service) leaseDatabase(ctx context.Context, source storedSource, password string) (*sql.DB, func(), error) {
	s.poolMu.Lock()
	if s.pools == nil {
		s.poolMu.Unlock()
		db, err := s.open(ctx, source.Source, password)
		if err != nil {
			return nil, nil, err
		}
		return db, func() { db.Close() }, nil
	}
	key := fmt.Sprintf("%s/%d", source.ID, source.Revision)
	p := s.pools[key]
	if p == nil {
		db, err := s.open(ctx, source.Source, password)
		if err != nil {
			s.poolMu.Unlock()
			return nil, nil, err
		}
		p = &databaseLease{db: db, source: source.ID}
		s.pools[key] = p
	}
	p.refs++
	s.poolMu.Unlock()
	return p.db, func() {
		s.poolMu.Lock()
		p.refs--
		closeNow := p.refs == 0 && p.retired
		s.poolMu.Unlock()
		if closeNow {
			p.db.Close()
		}
	}, nil
}

func (s *Service) retireDatabase(source string) {
	s.poolMu.Lock()
	var closing []*sql.DB
	for key, p := range s.pools {
		if source == "" || p.source == source {
			delete(s.pools, key)
			p.retired = true
			if p.refs == 0 {
				closing = append(closing, p.db)
			}
		}
	}
	s.poolMu.Unlock()
	for _, db := range closing {
		db.Close()
	}
}

func (s *Service) Close() { s.retireDatabase("") }
