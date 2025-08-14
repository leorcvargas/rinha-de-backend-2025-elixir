package main

import (
	"flag"
	"log"
	"net"
	"os"
	"runtime"
	"sync/atomic"
	"time"

	"github.com/valyala/fasthttp"
)

type Backend struct {
	socket string
	client *fasthttp.HostClient
}

type LoadBalancer struct {
	// api1 and api2
	backends [2]*Backend
	counter  uint64
}

func NewBackend(socket string, maxConns int) *Backend {
	return &Backend{
		socket: socket,
		client: &fasthttp.HostClient{
			Dial: func(addr string) (net.Conn, error) {
				return net.Dial("unix", socket)
			},
			MaxConns:                      maxConns,
			MaxConnWaitTimeout:            200 * time.Millisecond,
			MaxIdleConnDuration:           15 * time.Second,
			ReadTimeout:                   5 * time.Second,
			WriteTimeout:                  5 * time.Second,
			NoDefaultUserAgentHeader:      true,
			DisableHeaderNamesNormalizing: true,
			DisablePathNormalizing:        true,
		},
	}
}

func (lb *LoadBalancer) next() *Backend {
	i := atomic.AddUint64(&lb.counter, 1) & 1
	return lb.backends[i]
}

func (lb *LoadBalancer) alt(b *Backend) *Backend {
	if b == lb.backends[0] {
		return lb.backends[1]
	}
	return lb.backends[0]
}

func (lb *LoadBalancer) HandleRequest(ctx *fasthttp.RequestCtx) {
	b := lb.next()

	req := &ctx.Request
	resp := &ctx.Response

	if err := b.client.Do(req, resp); err != nil {
		other := lb.alt(b)
		if other != nil {
			if err2 := other.client.Do(req, resp); err2 == nil {
				return
			}
		}
		ctx.Error("Backend error", fasthttp.StatusBadGateway)
		return
	}
}

func waitForSocket(socket string) {
	for i := 0; i < 30; i++ {
		if st, err := os.Stat(socket); err == nil && (st.Mode()&os.ModeSocket) != 0 {
			log.Printf("Socket %s is ready", socket)
			return
		}
		log.Printf("Waiting for socket %s...", socket)
		time.Sleep(1 * time.Second)
	}
	log.Printf("Warning: Socket %s not found, continuing anyway", socket)
}

func main() {
	var (
		listenAddr = flag.String("addr", ":80", "Listen address")
		socket1    = flag.String("socket1", "/tmp/rinhex/api1.sock", "First backend socket")
		socket2    = flag.String("socket2", "/tmp/rinhex/api2.sock", "Second backend socket")

		// Matching my Bandit num of acceptors
		maxConns = flag.Int("maxconns", 1, "Max connections per backend")
	)
	flag.Parse()

	waitForSocket(*socket1)
	waitForSocket(*socket2)

	lb := &LoadBalancer{
		backends: [2]*Backend{
			NewBackend(*socket1, *maxConns),
			NewBackend(*socket2, *maxConns),
		},
	}

	server := &fasthttp.Server{
		Handler:                       lb.HandleRequest,
		MaxConnsPerIP:                 0,
		MaxRequestsPerConn:            0,
		ReadTimeout:                   5 * time.Second,
		WriteTimeout:                  5 * time.Second,
		IdleTimeout:                   120 * time.Second,
		TCPKeepalive:                  true,
		NoDefaultServerHeader:         true,
		NoDefaultContentType:          true,
		ReduceMemoryUsage:             true,
		DisableHeaderNamesNormalizing: true,
		ReadBufferSize:                512,
		WriteBufferSize:               512,
	}

	log.Printf("LB on %s (GOMAXPROCS=%d)", *listenAddr, runtime.GOMAXPROCS(0))
	log.Printf("Backends: %s, %s (maxconns=%d)", *socket1, *socket2, *maxConns)

	if err := server.ListenAndServe(*listenAddr); err != nil {
		log.Fatalf("Error starting server: %v", err)
	}
}
