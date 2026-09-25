package main

import (
	"context"
	"fmt"
	"github.com/jonace-mpelule/okestra/internal/updater"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/jonace-mpelule/okestra/internal/agent"
)

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "upgrade" || os.Args[1] == "update") {
		if len(os.Args) > 3 || (len(os.Args) == 3 && os.Args[2] != "--check") {
			fmt.Fprintln(os.Stderr, "usage: sudo okestra-service upgrade [--check]")
			os.Exit(1)
		}
		if err := updater.Upgrade(context.Background(), "okestra-service", len(os.Args) == 3, os.Stdout); err != nil {
			log.Fatal(err)
		}
		return
	}
	addr := getenv("OKESTRA_SERVICE_ADDR", getenv("OKESTRA_AGENT_ADDR", "127.0.0.1:8088"))
	token := getenv("OKESTRA_SERVICE_TOKEN", os.Getenv("OKESTRA_AGENT_TOKEN"))
	if token == "" {
		log.Fatal("OKESTRA_SERVICE_TOKEN is required; generate one with: openssl rand -hex 32")
	}
	if len(token) < 32 {
		log.Fatal("OKESTRA_SERVICE_TOKEN must be at least 32 characters")
	}
	workDir := getenv("OKESTRA_SERVICE_WORKDIR", getenv("OKESTRA_AGENT_WORKDIR", "/tmp/okestra-service"))
	dockerHost := os.Getenv("DOCKER_HOST")

	docker, err := agent.NewDockerClient(dockerHost)
	if err != nil {
		log.Fatal(err)
	}
	srv := agent.NewServer(addr, token, workDir, docker)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := srv.ListenAndServe(ctx); err != nil {
		log.Fatal(err)
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
