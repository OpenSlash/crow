package main

import (
	"log"

	"github.com/crow/crow/server/internal/config"
	"github.com/crow/crow/server/internal/server"
)

func main() {
	cfg := config.Load()
	if err := server.Run(cfg); err != nil {
		log.Fatal(err)
	}
}
