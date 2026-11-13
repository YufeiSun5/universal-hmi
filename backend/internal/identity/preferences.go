package identity

import (
	"database/sql"
	"errors"
	"regexp"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

type Preferences struct {
	Home     string `json:"home"`
	Revision int64  `json:"revision"`
}

var ErrPreferenceConflict = errors.New("首页设置已在其他终端修改，请刷新后重试")
var homePattern = regexp.MustCompile(`^[a-z][a-z-]{0,39}(/[a-z-]{1,30})?$`)

func (s *Service) Preferences(a authorization.Actor) (Preferences, error) {
	out := Preferences{}
	if a.ID == "" || !a.Active() {
		return out, ErrDenied
	}
	e := s.db.QueryRow("SELECT home,revision FROM user_preferences WHERE user_id=?", a.ID).Scan(&out.Home, &out.Revision)
	if e == sql.ErrNoRows {
		e = nil
	}
	return out, e
}

// The application validates the destination against current page access. This
// store accepts only stable identifiers and writes only the current account.
func (s *Service) SavePreferences(a authorization.Actor, in Preferences) (Preferences, error) {
	if a.ID == "" || !a.Active() {
		return Preferences{}, ErrDenied
	}
	if in.Revision < 0 || in.Home != "" && !homePattern.MatchString(in.Home) {
		return Preferences{}, errors.New("首页标识无效")
	}
	tx, e := s.db.Begin()
	if e != nil {
		return Preferences{}, e
	}
	defer tx.Rollback()
	if _, e = tx.Exec("INSERT INTO user_preferences(user_id,home,revision) VALUES(?,'',0) ON CONFLICT(user_id) DO NOTHING", a.ID); e != nil {
		return Preferences{}, e
	}
	// Lock the owned row before comparing revisions on both SQLite and PG.
	if _, e = tx.Exec("UPDATE user_preferences SET revision=revision WHERE user_id=?", a.ID); e != nil {
		return Preferences{}, e
	}
	var disabled int
	var version int64
	if e = tx.QueryRow("SELECT disabled,version FROM users WHERE id=?", a.ID).Scan(&disabled, &version); e != nil || disabled != 0 || version != a.Version {
		return Preferences{}, ErrDenied
	}
	var old Preferences
	if e = tx.QueryRow("SELECT home,revision FROM user_preferences WHERE user_id=?", a.ID).Scan(&old.Home, &old.Revision); e != nil {
		return old, e
	}
	// A lost response can be retried, but a stale different choice never wins.
	if old.Revision == in.Revision+1 && old.Home == in.Home {
		return old, nil
	}
	if old.Revision != in.Revision {
		return old, ErrPreferenceConflict
	}
	if old.Home == in.Home {
		return old, nil
	}
	in.Revision++
	if _, e = tx.Exec("UPDATE user_preferences SET home=?,revision=? WHERE user_id=?", in.Home, in.Revision, a.ID); e != nil {
		return old, e
	}
	if _, e = tx.Exec("INSERT INTO audit(at,actor,action,target,result) VALUES(?,?,?,?,?)", s.now().UTC().Format("2006-01-02T15:04:05Z"), a.ID, "account.home", a.ID, "saved"); e != nil {
		return old, e
	}
	return in, tx.Commit()
}
