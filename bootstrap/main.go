package main

import (
	"log"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
)

func main() {
	if err := bootstrap.Run(Wire); err != nil {
		log.Fatal(err)
	}
}
