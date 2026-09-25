package main

import (
	"os"

	"github.com/jonace-mpelule/okestra/internal/client"
)

func main() {
	os.Exit(client.RunCLI(os.Args[1:], os.Stdout, os.Stderr))
}
