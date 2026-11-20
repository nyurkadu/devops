package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

func handler(w http.ResponseWriter, r *http.Request) {
	greeting := os.Getenv("GREETING")
	if greeting == "" {
		greeting = "world"
	}
	fmt.Fprintf(w, "shalom, %s!!!\n%s\n", greeting, time.Now().Format("2006-01-02 15:04:05"))
}

func main() {
	http.HandleFunc("/", handler)
	http.ListenAndServe(":8086", nil)
}