package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/analysis"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
	"github.com/YufeiSun5/universal-hmi/backend/internal/server"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:18080", "listen address; non-loopback requires auth and TLS")
	dataDir := flag.String("data-dir", ".local", "local configuration directory")
	webDir := flag.String("web-dir", "", "built Flutter Web directory")
	devOrigin := flag.String("dev-origin", "", "exact allowed development browser origin")
	authFile := flag.String("auth-file", "", "operator-owned single-user JSON file with bcrypt password_hash")
	publicOrigin := flag.String("public-origin", "", "exact HTTPS browser origin, required with authentication")
	tlsCert := flag.String("tls-cert", "", "TLS certificate PEM file")
	tlsKey := flag.String("tls-key", "", "TLS private key PEM file")
	mcpWrite := flag.Bool("mcp-write", false, "explicitly allow MCP mutation tools (also requires account write permission)")
	flag.Parse()
	if err := validateListen(*listen, *authFile, *publicOrigin, *tlsCert, *tlsKey, *devOrigin); err != nil {
		log.Fatal(err)
	}
	var auth *server.Auth
	if *authFile != "" {
		var err error
		auth, err = server.LoadAuthFile(*authFile, *publicOrigin)
		if err != nil {
			log.Fatal(err)
		}
	}
	service, err := points.Open(*dataDir + "/points.json")
	if err != nil {
		log.Fatal(err)
	}
	db, err := storage.Open(*dataDir)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	engine, err := rt.New(service, db)
	if err != nil {
		log.Fatal(err)
	}
	defer engine.Close()
	files, err := analysis.New(db, service, *dataDir+"/exports")
	if err != nil {
		log.Fatal(err)
	}
	defer files.Close()
	api := server.PlatformHandler(service, engine, files, *webDir, *devOrigin)
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
	srv := &http.Server{Addr: *listen, Handler: handler,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdown); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}()
	log.Printf("Universal HMI listening on %s", *listen)
	var serveErr error
	if *tlsCert != "" {
		serveErr = srv.ListenAndServeTLS(*tlsCert, *tlsKey)
	} else {
		serveErr = srv.ListenAndServe()
	}
	if err := serveErr; err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
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
