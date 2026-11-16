package materials

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"strings"
)

// seedLegacyApplication reproduces pre-v97 records for historical read,
// signature, concurrency and inventory regressions. It is not in the product.
func (s *Service) seedLegacyApplication(ctx context.Context, in ApplicationInput) (Application, error) {
	return mutate(ctx, s, "request", "application", in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Application, error) {
		v := Application{}
		if !textValid(in.Text, 10000, true) {
			return v, invalid("申请正文（最多10000字）")
		}
		if in.ID == "" {
			if in.Version != 0 {
				return v, ErrConflict
			}
			v.ID = id()
			v.Number = number("SQ", v.ID)
			v.OwnerID = a.ID
			v.Owner = a.DisplayName
		} else {
			var e error
			v, e = getApplication(tx, in.ID)
			if e != nil {
				return v, e
			}
			if v.OwnerID != a.ID {
				return Application{}, authorization.ErrDenied
			}
			if v.Version != in.Version || v.Status != "rejected" {
				return Application{}, ErrConflict
			}
		}
		v.ApplicationVersion = ApplicationVersion{Version: v.Version + 1, Text: strings.TrimSpace(in.Text), Submitted: now(), Status: "pending"}
		_, e := tx.Exec("INSERT INTO materials_applications(id,owner_id,version,status,created,search,body) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version,status=excluded.status,created=excluded.created,search=excluded.search,body=excluded.body", v.ID, v.OwnerID, v.Version, v.Status, v.Submitted, strings.ToLower(v.Number+" "+v.Owner+" "+v.Text), raw(v))
		if e != nil {
			return v, e
		}
		_, e = tx.Exec("INSERT INTO materials_application_versions(application_id,version,body) VALUES(?,?,?)", v.ID, v.Version, raw(v.ApplicationVersion))
		return v, e
	})
}
