package totalreports

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/YufeiSun5/universal-hmi/backend/internal/objectstore"
)

func (s *Service) loadOriginal(ctx context.Context, id string) ([]byte, error) {
	var ref []byte
	if err := s.db.QueryRowContext(ctx, "SELECT data FROM total_report_originals WHERE id=?", id).Scan(&ref); err != nil {
		return nil, err
	}
	return s.files.Get(ctx, ref)
}

func (s *Service) migrateOriginals() error {
	last := ""
	for {
		var id string
		var data []byte
		err := s.db.QueryRow("SELECT id,data FROM total_report_originals WHERE id>? ORDER BY id LIMIT 1", last).Scan(&id, &data)
		if err == sql.ErrNoRows {
			return nil
		}
		if err != nil {
			return err
		}
		if objectstore.IsReference(data) {
			if _, err = s.files.Get(context.Background(), data); err != nil {
				return fmt.Errorf("report original %s: %w", id, err)
			}
		} else {
			if digest(data) != id {
				return fmt.Errorf("report original checksum mismatch: %s", id)
			}
			ref, e := s.files.Put(context.Background(), data)
			if e != nil {
				return e
			}
			if _, e = s.db.Exec("UPDATE total_report_originals SET data=? WHERE id=? AND data=?", ref, id, data); e != nil {
				return e
			}
		}
		last = id
	}
}
