package identity

import (
	"crypto/sha256"
	"net"
	"sort"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

const OnlineWindow = 90 * time.Second

type OnlineConnection struct {
	ID       string    `json:"id"`
	UserID   string    `json:"user_id"`
	Username string    `json:"username"`
	Channel  string    `json:"channel"`
	Client   string    `json:"client"`
	IP       string    `json:"ip"`
	Started  time.Time `json:"started"`
	LastSeen time.Time `json:"last_seen"`
}

type OnlineSnapshot struct {
	Items         []OnlineConnection `json:"items"`
	Connections   int                `json:"connections"`
	Users         int                `json:"users"`
	WindowSeconds int                `json:"window_seconds"`
}

// ObserveConnection is called only after transport authentication. It tracks
// communication separately from user activity and never extends a login lease.
func (s *Service) ObserveConnection(token, remoteAddr, userAgent string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := sha256.Sum256([]byte(token))
	v, ok := s.sessions[key]
	if !ok {
		return
	}
	ip, _, err := net.SplitHostPort(remoteAddr)
	if err != nil || net.ParseIP(ip) == nil {
		ip = ""
	}
	client := "浏览器"
	switch {
	case v.LinkedValid != nil:
		client = "KP"
	case strings.Contains(userAgent, "Android"):
		client = "Android"
	case strings.Contains(userAgent, "iPhone"), strings.Contains(userAgent, "iPad"):
		client = "iOS"
	case strings.Contains(userAgent, "Dart/"):
		client = "桌面客户端"
	case userAgent == "":
		client = "其他客户端"
	}
	v.presenceAt, v.presenceIP, v.presenceClient = s.now(), ip, client
	s.sessions[key] = v
}

// Online is an engineering-only read. No bearer, CSRF, certificate, or upstream
// credential is included. A session shared by browser tabs is counted once.
func (s *Service) Online(actor authorization.Actor) (OnlineSnapshot, error) {
	result := OnlineSnapshot{Items: []OnlineConnection{}, WindowSeconds: int(OnlineWindow.Seconds())}
	if !actor.Active() || actor.ReadOnly || !actor.Grants.Develop() {
		return result, ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.Current(actor.ID, actor.Version) {
		return result, ErrDenied
	}
	now := s.now()
	users := map[string]bool{}
	for _, v := range s.sessions {
		if v.presenceAt.IsZero() || now.Sub(v.presenceAt) >= OnlineWindow || v.timedOut(now) || (v.LinkedValid != nil && !v.LinkedValid()) {
			continue
		}
		u, err := s.User(v.UserID)
		if err != nil {
			return result, err
		}
		if u.Disabled || u.Version != v.Version {
			continue
		}
		if v.deviceLeaf != nil {
			d, err := s.verifyDeviceCertificateLocked(v.deviceLeaf)
			if err != nil || d.ApprovalID != v.deviceApproval {
				continue
			}
		}
		result.Items = append(result.Items, OnlineConnection{ID: v.ID, UserID: u.ID, Username: u.Username, Channel: v.Channel, Client: v.presenceClient, IP: v.presenceIP, Started: v.Started, LastSeen: v.presenceAt})
		users[u.ID] = true
	}
	sort.Slice(result.Items, func(i, j int) bool {
		if result.Items[i].Username != result.Items[j].Username {
			return result.Items[i].Username < result.Items[j].Username
		}
		return result.Items[i].ID < result.Items[j].ID
	})
	result.Connections, result.Users = len(result.Items), len(users)
	return result, nil
}
