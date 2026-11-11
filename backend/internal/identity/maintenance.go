package identity

import "github.com/YufeiSun5/universal-hmi/backend/internal/authorization"

// DeviceOwner exposes only the account labels needed to review an enrollment;
// approving devices does not grant access to user policies or user mutation.
type DeviceOwner struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Disabled bool   `json:"disabled"`
}

func (s *Service) DeviceOwners(a authorization.Actor) ([]DeviceOwner, error) {
	if !a.Active() || !(a.Grants.ApproveDevices() || a.Grants.ManageCertificates()) {
		return nil, ErrDenied
	}
	rows, err := s.db.Query("SELECT id,username,disabled FROM users ORDER BY username")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DeviceOwner{}
	for rows.Next() {
		var owner DeviceOwner
		if err = rows.Scan(&owner.ID, &owner.Username, &owner.Disabled); err != nil {
			return nil, err
		}
		out = append(out, owner)
	}
	return out, rows.Err()
}
