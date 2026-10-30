package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/desktopservice"
	"github.com/jackc/pgx/v5"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
)

type settings struct {
	ProjectConfig string `json:"projectConfig"`
	PostgresBin   string `json:"postgresBin"`
	PostgresData  string `json:"postgresData"`
}
type project struct {
	Server         string `json:"server"`
	Data           string `json:"data"`
	Web            string `json:"web"`
	DatabaseConfig string `json:"databaseConfig"`
	RemoteConfig   string `json:"remoteConfig"`
	Port           int    `json:"port"`
}
type host struct {
	cfg       settings
	project   project
	root      string
	db        *pgx.ConnConfig
	child     *exec.Cmd
	done      chan error
	event     windows.Handle
	eventName string
	pgPID     string
	started   chan struct{}
}

func read(path string, v any) error {
	b, e := os.ReadFile(path)
	if e != nil {
		return e
	}
	return json.Unmarshal(b, v)
}
func absolute(root, p string) string {
	if p == "" {
		return ""
	}
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Join(root, p)
}
func (h *host) pg(args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 65*time.Second)
	defer cancel()
	c := exec.CommandContext(ctx, filepath.Join(h.cfg.PostgresBin, "pg_ctl.exe"), args...)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	return c.Run()
}
func (h *host) Preflight() error {
	if h.project.Port < 1024 || h.project.Port > 65535 {
		return errors.New("invalid project port")
	}
	for _, p := range []string{h.project.Server, h.project.Data, h.project.Web, h.project.DatabaseConfig, filepath.Join(h.cfg.PostgresBin, "pg_ctl.exe"), filepath.Join(h.cfg.PostgresData, "PG_VERSION")} {
		if !filepath.IsAbs(p) {
			return fmt.Errorf("absolute configured path required: %s", p)
		}
		if _, e := os.Stat(p); e != nil {
			return e
		}
	}
	var db struct {
		DSN string `json:"dsn"`
	}
	if e := read(h.project.DatabaseConfig, &db); e != nil {
		return e
	}
	c, e := pgx.ParseConfig(db.DSN)
	if e != nil {
		return errors.New("invalid database DSN")
	}
	if c.Host != "127.0.0.1" {
		return errors.New("service requires a dedicated loopback PostgreSQL cluster")
	}
	h.db = c
	for _, port := range []int{h.project.Port, int(c.Port)} {
		l, e := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if e != nil {
			return fmt.Errorf("port %d already occupied; stop existing project/database before service start", port)
		}
		l.Close()
	}
	if h.pg("status", "-D", h.cfg.PostgresData) == nil {
		return errors.New("PostgreSQL already running; refusing to adopt it")
	}
	if _, e := os.Stat(filepath.Join(h.cfg.PostgresData, "postmaster.pid")); e == nil {
		return errors.New("postmaster.pid exists; inspect cluster offline before starting")
	}
	return nil
}
func (h *host) StartDatabase() error {
	if e := h.pg("start", "-D", h.cfg.PostgresData, "-l", filepath.Join(h.root, "service-postgres.log"), "-o", fmt.Sprintf("-h 127.0.0.1 -p %d", h.db.Port), "-w", "-t", "45"); e != nil {
		return e
	}
	b, e := os.ReadFile(filepath.Join(h.cfg.PostgresData, "postmaster.pid"))
	if e != nil {
		return e
	}
	h.pgPID = strings.SplitN(string(b), "\n", 2)[0]
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, e := pgx.ConnectConfig(ctx, h.db)
	if e != nil {
		_ = h.StopDatabase()
		return errors.New("dedicated database connection failed")
	}
	defer conn.Close(ctx)
	var path string
	e = conn.QueryRow(ctx, "SHOW data_directory").Scan(&path)
	if e != nil || !strings.EqualFold(filepath.Clean(path), filepath.Clean(h.cfg.PostgresData)) {
		_ = h.StopDatabase()
		return errors.New("database cluster identity mismatch")
	}
	return nil
}
func (h *host) StartBackend() error {
	var nonce [16]byte
	if _, e := rand.Read(nonce[:]); e != nil {
		return e
	}
	h.eventName = "Global\\UniversalHMIStop-" + hex.EncodeToString(nonce[:])
	p, _ := windows.UTF16PtrFromString(h.eventName)
	ev, e := windows.CreateEvent(nil, 1, 0, p)
	if e != nil {
		return e
	}
	h.event = ev
	base := "http://127.0.0.1:" + strconv.Itoa(h.project.Port)
	args := []string{"--listen", "127.0.0.1:" + strconv.Itoa(h.project.Port), "--data-dir", h.project.Data, "--web-dir", h.project.Web, "--database-config", h.project.DatabaseConfig, "--identity", "--identity-local-setup", "--public-origin", base, "--shutdown-event", h.eventName}
	if h.project.RemoteConfig != "" {
		args = append(args, "--remote-config", h.project.RemoteConfig)
	}
	h.child = exec.Command(h.project.Server, args...)
	h.child.Dir = h.root
	h.child.Stdout = os.Stdout
	h.child.Stderr = os.Stderr
	if e = h.child.Start(); e != nil {
		windows.CloseHandle(ev)
		h.event = 0
		return e
	}
	h.done = make(chan error, 1)
	go func() { h.done <- h.child.Wait(); close(h.done) }()
	close(h.started)
	return nil
}
func (h *host) WaitBackend(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return nil
	case e := <-h.done:
		return e
	}
}
func (h *host) StopBackend() error {
	if h.event != 0 {
		defer windows.CloseHandle(h.event)
		if e := windows.SetEvent(h.event); e != nil {
			return e
		}
	}
	select {
	case <-h.done:
		return nil
	case <-time.After(45 * time.Second):
		return errors.New("graceful shutdown timed out; no forced termination performed")
	}
}
func (h *host) StopDatabase() error {
	b, e := os.ReadFile(filepath.Join(h.cfg.PostgresData, "postmaster.pid"))
	if os.IsNotExist(e) {
		return nil
	}
	if e != nil {
		return e
	}
	if h.pgPID == "" || strings.SplitN(string(b), "\n", 2)[0] != h.pgPID {
		return errors.New("database owner PID changed; refusing stop")
	}
	return h.pg("stop", "-D", h.cfg.PostgresData, "-m", "fast", "-w", "-t", "45")
}

type service struct{ h *host }

func (s *service) Execute(_ []string, r <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	status <- svc.Status{State: svc.StartPending, WaitHint: 120000}
	done := make(chan error, 1)
	s.h.started = make(chan struct{})
	started := s.h.started
	go func() { done <- desktopservice.Run(ctx, s.h) }()
	for {
		select {
		case <-started:
			started = nil
			status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown | svc.AcceptPreShutdown}
		case e := <-done:
			if e != nil {
				fmt.Fprintln(os.Stderr, e)
				return false, 1
			}
			return false, 0
		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				status <- c.CurrentStatus
			case svc.Stop, svc.Shutdown, svc.PreShutdown:
				status <- svc.Status{State: svc.StopPending, WaitHint: 100000}
				cancel()
			}
		}
	}
}
func main() {
	config := flag.String("config", "", "absolute service configuration")
	name := flag.String("name", "UniversalHMI", "Windows service name")
	check := flag.Bool("check", false, "validate files and exclusive ports without starting processes")
	flag.Parse()
	if !filepath.IsAbs(*config) {
		fmt.Fprintln(os.Stderr, "absolute --config required")
		os.Exit(1)
	}
	h := &host{root: filepath.Dir(*config)}
	if e := read(*config, &h.cfg); e != nil {
		panic(e)
	}
	h.cfg.ProjectConfig = absolute(h.root, h.cfg.ProjectConfig)
	if e := read(h.cfg.ProjectConfig, &h.project); e != nil {
		panic(e)
	}
	pr := filepath.Dir(h.cfg.ProjectConfig)
	h.project.Server = absolute(pr, h.project.Server)
	h.project.Data = absolute(pr, h.project.Data)
	h.project.Web = absolute(pr, h.project.Web)
	h.project.DatabaseConfig = absolute(pr, h.project.DatabaseConfig)
	h.project.RemoteConfig = absolute(pr, h.project.RemoteConfig)
	h.cfg.PostgresBin = absolute(h.root, h.cfg.PostgresBin)
	h.cfg.PostgresData = absolute(h.root, h.cfg.PostgresData)
	log, e := os.OpenFile(filepath.Join(h.root, "service-host.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if e != nil {
		panic(e)
	}
	defer log.Close()
	os.Stdout = log
	os.Stderr = log
	if *check {
		if e = h.Preflight(); e != nil {
			fmt.Fprintln(log, e)
			os.Exit(1)
		}
		return
	}
	if e = svc.Run(*name, &service{h}); e != nil {
		fmt.Fprintln(log, e)
		os.Exit(1)
	}
}
