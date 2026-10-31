package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/analysis"
	"github.com/YufeiSun5/universal-hmi/backend/internal/desktopservice"
	"github.com/YufeiSun5/universal-hmi/backend/internal/equipment"
	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
	"github.com/YufeiSun5/universal-hmi/backend/internal/server"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:18080", "listen address; non-loopback requires auth and TLS")
	autoPort := flag.Bool("auto-port", false, "desktop only: use an OS-assigned loopback port when preferred port is unavailable")
	endpointFile := flag.String("endpoint-file", "", "desktop only: write actual URL and PID to this per-launch file")
	dataDir := flag.String("data-dir", ".local", "local configuration directory")
	webDir := flag.String("web-dir", "", "built Flutter Web directory")
	devOrigin := flag.String("dev-origin", "", "exact allowed development browser origin")
	authFile := flag.String("auth-file", "", "operator-owned single-user JSON file with bcrypt password_hash")
	publicOrigin := flag.String("public-origin", "", "exact HTTPS browser origin, required with authentication")
	tlsCert := flag.String("tls-cert", "", "TLS certificate PEM file")
	tlsKey := flag.String("tls-key", "", "TLS private key PEM file")
	mcpWrite := flag.Bool("mcp-write", false, "explicitly allow MCP mutation tools (also requires account write permission)")
	kpFile := flag.String("kp-config", "", "operator-owned KP bridge configuration; disabled by default")
	kpTrial := flag.Bool("kp-local-trial", false, "explicit loopback-only username trial; never a production identity verifier")
	identityEnabled := flag.Bool("identity", false, "enable managed users, roles, scopes and revocable sessions")
	identityLocal := flag.Bool("identity-local-setup", false, "explicit loopback-only HTTP setup/evaluation; never remotely proxy this listener")
	databaseConfig := flag.String("database-config", "", "private PostgreSQL JSON config; defaults to data-dir/database.json when present")
	migrate := flag.Bool("migrate-sqlite", false, "one-time import from stopped legacy data-dir into empty PostgreSQL, then exit")
	shutdownEvent := flag.String("shutdown-event", "", "private Windows service-host stop event")
	remotePath := flag.String("remote-config", "", "optional project-owned remote HTTPS JSON configuration")
	flag.Parse()
	// Public configuration failure must not stop local acquisition or repair.
	remote, err := loadRemoteConfig(*remotePath, false)
	remoteConfigError := ""
	disablePublic := func(reason string) {
		remote.Config.Enabled = false
		remoteConfigError = reason
		if raw, e := os.ReadFile(*remotePath); e == nil {
			remote.Digest = fmt.Sprintf("%x", sha256.Sum256(raw))
		}
		log.Printf("Public HTTPS disabled: %s", reason)
	}
	if err != nil {
		disablePublic("invalid remote configuration; review schema, IP rules and TLS files")
	}
	host, _, listenError := net.SplitHostPort(*listen)
	if listenError != nil || !server.IsLoopbackHost(host) {
		log.Fatal("management listener must be loopback; public access requires remote-config")
	}
	if remote.Config.Enabled {
		if err := validateRemotePrivatePath(*remotePath, remote.Config.PrivateKey, *webDir); err != nil {
			disablePublic("remote private key must remain outside served frontend files")
		}
	}
	if remote.Config.Enabled && (!*identityEnabled || !*identityLocal || *kpFile != "" || *authFile != "" || *tlsCert != "" || *tlsKey != "") {
		disablePublic("remote-config requires managed loopback identity setup without legacy/KP/TLS flags")
	}
	validatedAuth := *authFile
	if *identityLocal && !*identityEnabled {
		log.Fatal("identity-local-setup requires identity")
	}
	if *identityEnabled {
		if *authFile != "" || *kpTrial || (*kpFile != "" && *identityLocal) || *devOrigin != "" || (*autoPort && !*identityLocal) {
			log.Fatal("identity cannot be combined with legacy auth, KP trial, dev-origin or remote auto-port")
		}
		validatedAuth = "managed-identity"
	}
	if *identityLocal {
		if *autoPort && *publicOrigin == "" {
			*publicOrigin = "http://" + *listen
		}
		host, _, err := net.SplitHostPort(*listen)
		u, e := url.Parse(*publicOrigin)
		if err != nil || e != nil || !server.IsLoopbackHost(host) || u.Host != *listen || u.Scheme != "http" || *tlsCert != "" || *tlsKey != "" {
			log.Fatal("identity-local-setup requires exact loopback HTTP listen/public-origin and no TLS")
		}
	}
	if err := validateKPListen(*listen, validatedAuth, *publicOrigin, *tlsCert, *tlsKey, *devOrigin, *kpFile, *kpTrial); err != nil && !*identityLocal {
		log.Fatal(err)
	}
	if (*autoPort || *endpointFile != "") && !*identityLocal && (*authFile != "" || *publicOrigin != "" || *tlsCert != "" || *kpFile != "" || *devOrigin != "") {
		log.Fatal("desktop endpoint discovery cannot be combined with remote/authenticated deployment options")
	}
	if *endpointFile != "" && !*autoPort {
		log.Fatal("endpoint-file requires auto-port")
	}
	var auth *server.Auth
	if *authFile != "" {
		var err error
		auth, err = server.LoadAuthFile(*authFile, *publicOrigin)
		if err != nil {
			log.Fatal(err)
		}
	}
	var bridge *kpbridge.Service
	var kpOptions server.KPOptions
	if *kpFile != "" {
		config, err := server.LoadKPFile(*kpFile)
		if err != nil {
			log.Fatal(err)
		}
		bridge, err = server.NewKPService(config, *kpTrial, nil)
		if err != nil {
			log.Fatal(err)
		}
		kpOptions = server.KPOptions{PublicOrigin: *publicOrigin, WebDir: *webDir, KPOrigins: config.KPOrigins, LocalTrial: *kpTrial}
		if err := server.ValidateKPOptions(kpOptions); err != nil {
			log.Fatal(err)
		}
	}
	listener, err := desktopListener(*listen, *autoPort)
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	if *identityLocal && *autoPort {
		*publicOrigin = "http://" + listener.Addr().String()
	}
	var dsn string
	if *databaseConfig == "" {
		path := *dataDir + "/database.json"
		if _, e := os.Stat(path); e == nil {
			*databaseConfig = path
		} else if !os.IsNotExist(e) {
			log.Fatal("cannot inspect database configuration")
		}
	}
	if *databaseConfig != "" {
		dsn, err = persistence.ConfigFile(*databaseConfig)
		if err != nil {
			log.Fatal(err)
		}
	}
	if *migrate && dsn == "" {
		log.Fatal("migration requires PostgreSQL configuration")
	}
	db, err := storage.OpenDatabase(*dataDir, dsn)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	var documents *persistence.Documents
	var pointStore points.DocumentStore
	var screenStore process.DocumentStore
	if dsn != "" {
		lease, e := db.DB.Lease(context.Background())
		if e != nil {
			log.Fatal(e)
		}
		defer lease.Close()
		documents, err = persistence.NewDocuments(db.DB)
		if err != nil {
			log.Fatal(err)
		}
		pointStore = documents
		screenStore = documents
		if *migrate {
			if _, e := points.Open(*dataDir + "/points.json"); e != nil {
				log.Fatal(e)
			}
			if _, e := process.Open(*dataDir + "/screens"); e != nil {
				log.Fatal(e)
			}
			security, e := identity.OpenDatabase(*dataDir+"/security", dsn)
			if e != nil {
				log.Fatal(e)
			}
			defer security.Close()
			counts, e := persistence.ImportLegacy(context.Background(), *dataDir, db.DB)
			if e != nil {
				log.Fatal(e)
			}
			log.Printf("PostgreSQL migration verified and committed: %v", counts)
			return
		}
		// Fail closed if the dedicated lease connection is lost, so cached engines
		// cannot continue after another server acquires the project's lease.
		go func() {
			ticker := time.NewTicker(time.Second)
			defer ticker.Stop()
			for range ticker.C {
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				e := lease.PingContext(ctx)
				cancel()
				if e != nil {
					log.Fatal("PostgreSQL project lease lost; backend stopped")
				}
			}
		}()
	}
	service, err := points.OpenDocuments(*dataDir+"/points.json", pointStore)
	if err != nil {
		log.Fatal(err)
	}
	engine, err := rt.New(service, db)
	if err != nil {
		log.Fatal(err)
	}
	defer engine.Close()
	var identities *identity.Service
	if *identityEnabled {
		identities, err = identity.OpenDatabase(*dataDir+"/security", dsn, identity.Options{LocalPasswords: *identityLocal && !remote.Config.Enabled})
		if err != nil {
			log.Fatal(err)
		}
		defer identities.Close()
		bootstrap := make([]identity.PublicIPRule, 0, len(remote.Config.WebAllowlist))
		for _, rule := range remote.Config.WebAllowlist {
			bootstrap = append(bootstrap, identity.PublicIPRule{CIDR: rule.CIDR, OwnerLabel: rule.Owner, Enabled: true})
		}
		if e := identities.InitPublicIPPolicy(bootstrap); e != nil {
			disablePublic("public IP policy initialization failed")
		}
		if e := identities.InitPublicAccessAudit(); e != nil {
			log.Print("Public request audit unavailable; local management and access policy remain active")
		}
		engine.RequireIdentity()
	}
	files, err := analysis.New(db, service, *dataDir+"/exports")
	if err != nil {
		log.Fatal(err)
	}
	defer files.Close()
	screens, err := process.OpenDocuments(*dataDir+"/screens", screenStore)
	if err != nil {
		log.Fatal(err)
	}
	external, err := externaldata.Open(db, *dataDir+"/external-data")
	if err != nil {
		log.Fatal(err)
	}
	api := server.ExternalDataHandler(server.PlatformHandler(service, engine, files, *webDir, *devOrigin, screens), external, *devOrigin)

	directory := server.StationDirectory(service, engine, screens)
	ledger, err := equipment.Open(db, *dataDir+"/equipment/photos", func() ([]string, error) {
		items, e := directory.List()
		names := []string{}
		for _, st := range items {
			names = append(names, st.Name)
		}
		return names, e
	}, equipment.StatusPorts{Catalog: service, Live: engine})
	if err != nil {
		log.Fatal(err)
	}
	api = server.EquipmentHandler(api, ledger, *devOrigin)
	if identities != nil {
		syncStations := func() error {
			names := []string{}
			if err := db.LoadConfig("station_directory", &names); err != nil {
				return err
			}
			for _, p := range service.List() {
				names = append(names, p.Station)
			}
			items, e := screens.ListAll()
			if e != nil {
				return e
			}
			for _, d := range items {
				names = append(names, d.Station)
			}
			rows, e := db.DB.Query("SELECT DISTINCT station FROM samples")
			if e != nil {
				return e
			}
			for rows.Next() {
				var name string
				if e = rows.Scan(&name); e != nil {
					rows.Close()
					return e
				}
				names = append(names, name)
			}
			e = rows.Err()
			rows.Close()
			if e != nil {
				return e
			}
			return identities.RegisterStations(names)
		}
		if err = syncStations(); err != nil {
			log.Fatal(err)
		}
		baseAPI := api
		api = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			baseAPI.ServeHTTP(w, r)
			if r.Method == "POST" || r.Method == "PUT" {
				if err := syncStations(); err != nil {
					log.Printf("station registry refresh failed: %v", err)
				}
			}
		})
	}
	mux := http.NewServeMux()
	mux.Handle("/mcp", server.NewMCPHandler(api, server.MCPOptions{
		AllowWrite: *mcpWrite, DevOrigin: *devOrigin,
		Authorize: func(r *http.Request, write bool) bool {
			principal, ok := server.PrincipalFromContext(r.Context())
			return ok && (!write || principal.AllowWrite)
		},
	}))
	mux.Handle("/", api)
	handler := auth.Handler(mux)
	if auth == nil {
		handler = server.LocalAuthHandler(mux, *devOrigin)
	}
	if identities != nil {
		handler, err = server.IdentityHandler(identities, server.IdentityOptions{Origin: *publicOrigin, LocalSetup: *identityLocal}, mux)
		if err != nil {
			log.Fatal(err)
		}
	}
	if *kpFile != "" {
		var legacy http.Handler
		if auth != nil || identities != nil {
			legacy = handler
		}
		kpOptions.Identity = identities
		handler, err = server.KPHandler(bridge, kpOptions, legacy, mux)
		if err != nil {
			log.Fatal(err)
		}
	}
	srv := &http.Server{Addr: *listen, Handler: handler,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
	servers := []*http.Server{srv}
	listeners := []net.Listener{listener}
	{
		baseHandler := srv.Handler
		srv.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/api/v1/local/deployment" {
				host, _, e := net.SplitHostPort(r.RemoteAddr)
				if e != nil || !server.IsLoopbackHost(host) || r.Host != listener.Addr().String() || r.Header.Get("Origin") != "" || r.Header.Get("Forwarded") != "" || r.Header.Get("X-Forwarded-For") != "" || r.Header.Get("X-Forwarded-Host") != "" || r.Header.Get("X-Forwarded-Proto") != "" || (r.Method != "GET" && r.Method != "HEAD") {
					http.Error(w, "local only", 403)
					return
				}
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("Cache-Control", "no-store")
				fmt.Fprintf(w, `{"remote_config_sha256":%q,"remote_enabled":%t,"remote_config_error":%q}`, remote.Digest, remote.Config.Enabled, remoteConfigError)
				return
			}
			baseHandler.ServeHTTP(w, r)
		})
	}
	if remote.Config.Enabled {
		options := server.IdentityOptions{Origin: remote.Config.Origin, PublicReadOnly: true}
		remoteHandler, e := server.IdentityHandler(identities, options, api)
		var static http.Handler = http.NotFoundHandler()
		if *webDir != "" {
			static = http.FileServer(http.Dir(*webDir))
		}
		if e == nil {
			static, e = server.IdentityHandler(identities, options, static)
		}
		if e == nil {
			remoteHandler, e = server.PublicAccessHandler(remoteHandler, server.PublicAccessOptions{Evaluate: func(ip netip.Addr) server.PublicIPApproval {
				rule, allowed := identities.PublicIPMatch(ip)
				return server.PublicIPApproval{Allowed: allowed, RuleID: rule.ID, OwnerLabel: rule.OwnerLabel, OwnerUserID: rule.OwnerUserID}
			}, Static: static})
		}
		if e == nil {
			remoteHandler = server.PublicAccessAuditHandler(remoteHandler, identities)
		}
		if e != nil {
			disablePublic("public authentication or IP policy initialization failed")
		} else {
			remoteListener, e := net.Listen("tcp", remote.Config.Listen)
			if e != nil {
				disablePublic("public listener unavailable")
			} else {
				defer remoteListener.Close()
				remoteServer := &http.Server{Handler: remoteHandler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
				servers = append(servers, remoteServer)
				listeners = append(listeners, tls.NewListener(remoteListener, remote.TLS))
				log.Printf("Public readonly HTTPS configured: %s; certificate changes require restart; approved IP policy updates apply live", remote.Config.Origin)
			}
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := desktopservice.WatchShutdown(ctx, *shutdownEvent, stop); err != nil {
		log.Fatal(err)
	}
	if *endpointFile != "" {
		if err := writeDesktopEndpoint(*endpointFile, listener); err != nil {
			log.Fatal(err)
		}
	}
	log.Printf("Universal HMI listening on %s", listener.Addr())
	if *tlsCert != "" {
		pair, e := tls.LoadX509KeyPair(*tlsCert, *tlsKey)
		if e != nil {
			log.Fatal(e)
		}
		listeners[0] = tls.NewListener(listener, &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}})
	}
	if err := serveListeners(ctx, servers, listeners); err != nil {
		log.Print(err)
	}

}

func validateKPListen(listen, authFile, origin, cert, key, devOrigin, kpFile string, trial bool) error {
	if kpFile == "" {
		if trial {
			return fmt.Errorf("kp-local-trial requires kp-config")
		}
		return validateListen(listen, authFile, origin, cert, key, devOrigin)
	}
	if trial {
		host, _, e := net.SplitHostPort(listen)
		u, ue := url.Parse(origin)
		if e != nil || !server.IsLoopbackHost(host) || ue != nil || u.Scheme != "http" || !server.IsLoopbackHost(u.Hostname()) || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery || authFile != "" || cert != "" || key != "" || devOrigin != "" {
			return fmt.Errorf("KP local trial requires an isolated loopback HTTP origin, no auth-file, TLS or dev-origin")
		}
		return nil
	}
	configuredAuth := authFile
	if configuredAuth == "" {
		configuredAuth = "kp-config"
	}
	return validateListen(listen, configuredAuth, origin, cert, key, devOrigin)
}

// validateListen is fail-closed before any data files or sockets are opened.
func validateListen(listen, authFile, publicOrigin, tlsCert, tlsKey, devOrigin string) error {
	host, _, err := net.SplitHostPort(listen)
	if err != nil {
		return fmt.Errorf("invalid listen address: %w", err)
	}
	if (tlsCert == "") != (tlsKey == "") {
		return fmt.Errorf("tls-cert and tls-key must be supplied together")
	}
	if !server.IsLoopbackHost(host) && (authFile == "" || tlsCert == "") {
		return fmt.Errorf("non-loopback listeners require explicitly configured authentication and TLS")
	}
	if authFile == "" {
		if publicOrigin != "" {
			return fmt.Errorf("public-origin requires auth-file")
		}
		return nil
	}
	if tlsCert == "" {
		return fmt.Errorf("authentication requires TLS even on loopback")
	}
	if devOrigin != "" {
		return fmt.Errorf("dev-origin cannot be combined with authentication; use the same HTTPS origin")
	}
	u, err := url.Parse(publicOrigin)
	if err != nil || u == nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Path != "" || u.ForceQuery || u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("authentication requires an exact HTTPS public-origin without a path, query or fragment")
	}
	return nil
}
