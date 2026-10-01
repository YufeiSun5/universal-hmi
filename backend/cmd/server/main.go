package main

import (
	"context"
	"flag"
	"log"
	"net"
	"net/http"
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
	listen := flag.String("listen", "127.0.0.1:18080", "loopback address")
	dataDir := flag.String("data-dir", ".local", "local configuration directory")
	webDir := flag.String("web-dir", "", "built Flutter Web directory")
	devOrigin := flag.String("dev-origin", "", "exact allowed development browser origin")
	flag.Parse()
	host, _, err := net.SplitHostPort(*listen)
	if err != nil {
		log.Fatal(err)
	}
	ip := net.ParseIP(host)
	if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		log.Fatal("this bootstrap supports loopback only; remote access requires authentication")
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
	srv := &http.Server{Addr: *listen, Handler: server.PlatformHandler(service, engine, files, *webDir, *devOrigin),
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
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
