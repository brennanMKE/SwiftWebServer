// Command go-api is a minimal REST API used as the upstream app for the
// SwiftWebServer reverse proxy (milestone M17). It uses only the Go standard
// library and keeps its data in memory.
//
// The proxy mounts it at /api, so it serves the full /api/... paths itself
// (proxy "stripPrefix": false). Run it with:
//
//	go run ./Examples/go-api                     # 127.0.0.1:9000
//	go run ./Examples/go-api -addr 127.0.0.1:9100
//	go run ./Examples/go-api -unix /tmp/go-api.sock
//
// Endpoints:
//
//	GET    /api/health          {"status":"ok"}
//	GET    /api/items           list items
//	POST   /api/items           create {"name": "...", "done": false}
//	GET    /api/items/{id}      one item
//	PUT    /api/items/{id}      replace an item
//	DELETE /api/items/{id}      delete an item
//	GET    /api/echo            request details as seen by the app, including
//	                            the X-Forwarded-* headers the proxy adds
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"
)

type item struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
	Done bool   `json:"done"`
}

type store struct {
	mu     sync.Mutex
	nextID int
	items  map[int]item
}

func newStore() *store {
	return &store{nextID: 1, items: map[int]item{}}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func readItem(r *http.Request) (item, error) {
	var in item
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return item{}, err
	}
	if in.Name == "" {
		return item{}, errors.New("name is required")
	}
	return in, nil
}

func (s *store) routes() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("GET /api/items", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		list := make([]item, 0, len(s.items))
		for _, it := range s.items {
			list = append(list, it)
		}
		s.mu.Unlock()
		sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
		writeJSON(w, http.StatusOK, list)
	})

	mux.HandleFunc("POST /api/items", func(w http.ResponseWriter, r *http.Request) {
		in, err := readItem(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		s.mu.Lock()
		in.ID = s.nextID
		s.nextID++
		s.items[in.ID] = in
		s.mu.Unlock()
		w.Header().Set("Location", "/api/items/"+strconv.Itoa(in.ID))
		writeJSON(w, http.StatusCreated, in)
	})

	withID := func(h func(http.ResponseWriter, *http.Request, int)) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			id, err := strconv.Atoi(r.PathValue("id"))
			if err != nil || id < 1 {
				writeError(w, http.StatusBadRequest, "invalid id")
				return
			}
			h(w, r, id)
		}
	}

	mux.HandleFunc("GET /api/items/{id}", withID(func(w http.ResponseWriter, r *http.Request, id int) {
		s.mu.Lock()
		it, ok := s.items[id]
		s.mu.Unlock()
		if !ok {
			writeError(w, http.StatusNotFound, "not found")
			return
		}
		writeJSON(w, http.StatusOK, it)
	}))

	mux.HandleFunc("PUT /api/items/{id}", withID(func(w http.ResponseWriter, r *http.Request, id int) {
		in, err := readItem(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		s.mu.Lock()
		_, ok := s.items[id]
		if ok {
			in.ID = id
			s.items[id] = in
		}
		s.mu.Unlock()
		if !ok {
			writeError(w, http.StatusNotFound, "not found")
			return
		}
		writeJSON(w, http.StatusOK, in)
	}))

	mux.HandleFunc("DELETE /api/items/{id}", withID(func(w http.ResponseWriter, r *http.Request, id int) {
		s.mu.Lock()
		_, ok := s.items[id]
		delete(s.items, id)
		s.mu.Unlock()
		if !ok {
			writeError(w, http.StatusNotFound, "not found")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))

	mux.HandleFunc("GET /api/echo", func(w http.ResponseWriter, r *http.Request) {
		headers := map[string]string{}
		for k, v := range r.Header {
			if len(v) > 0 {
				headers[k] = v[0]
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"method":     r.Method,
			"path":       r.URL.Path,
			"query":      r.URL.RawQuery,
			"host":       r.Host,
			"proto":      r.Proto,
			"remoteAddr": r.RemoteAddr,
			"headers":    headers,
		})
	})

	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "no such endpoint")
	})
	return mux
}

func main() {
	addr := flag.String("addr", "127.0.0.1:9000", "TCP address to listen on (loopback by default)")
	unixPath := flag.String("unix", "", "listen on this Unix domain socket instead of TCP")
	flag.Parse()

	var ln net.Listener
	var err error
	if *unixPath != "" {
		_ = os.Remove(*unixPath)
		ln, err = net.Listen("unix", *unixPath)
	} else {
		ln, err = net.Listen("tcp", *addr)
	}
	if err != nil {
		log.Fatal(err)
	}

	srv := &http.Server{
		Handler:           newStore().routes(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()

	log.Printf("go-api listening on %s", ln.Addr())
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
