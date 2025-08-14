package main

import (
	"flag"
	"log"
	"net"
	"os"
	"sync/atomic"
	"time"

	"github.com/valyala/fasthttp"
)

type Backend struct {
	socket string
	client *fasthttp.Client
}

type LoadBalancer struct {
	backends []*Backend
	counter  uint64
}

func NewBackend(socket string) *Backend {
	return &Backend{
		socket: socket,
		client: &fasthttp.Client{
			Dial: func(addr string) (net.Conn, error) {
				return net.Dial("unix", socket)
			},
			MaxConnsPerHost:     100,
			MaxIdleConnDuration: 10 * time.Second,
			ReadTimeout:         10 * time.Second,
			WriteTimeout:        10 * time.Second,
		},
	}
}

func (lb *LoadBalancer) getNextBackend() *Backend {
	if len(lb.backends) == 0 {
		return nil
	}
	idx := atomic.AddUint64(&lb.counter, 1) % uint64(len(lb.backends))
	return lb.backends[idx]
}

func (lb *LoadBalancer) HandleRequest(ctx *fasthttp.RequestCtx) {
	backend := lb.getNextBackend()
	if backend == nil {
		ctx.Error("No backends available", fasthttp.StatusServiceUnavailable)
		return
	}

	req := fasthttp.AcquireRequest()
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseRequest(req)
	defer fasthttp.ReleaseResponse(resp)

	ctx.Request.CopyTo(req)

	req.SetHost("localhost")
	req.URI().SetScheme("http")
	req.URI().SetHost("localhost")

	err := backend.client.Do(req, resp)
	if err != nil {
		log.Printf("Error forwarding request to %s: %v", backend.socket, err)
		ctx.Error("Backend error", fasthttp.StatusBadGateway)
		return
	}

	resp.CopyTo(&ctx.Response)
}

func main() {
	var (
		listenAddr = flag.String("addr", ":80", "Listen address")
		socket1    = flag.String("socket1", "/tmp/rinhex/api1.sock", "First backend socket")
		socket2    = flag.String("socket2", "/tmp/rinhex/api2.sock", "Second backend socket")
	)
	flag.Parse()

	waitForSocket := func(socket string) {
		for i := 0; i < 30; i++ {
			if _, err := os.Stat(socket); err == nil {
				log.Printf("Socket %s is ready", socket)
				return
			}
			log.Printf("Waiting for socket %s...", socket)
			time.Sleep(1 * time.Second)
		}
		log.Printf("Warning: Socket %s not found, continuing anyway", socket)
	}

	waitForSocket(*socket1)
	waitForSocket(*socket2)

	lb := &LoadBalancer{
		backends: []*Backend{
			NewBackend(*socket1),
			NewBackend(*socket2),
		},
	}

	server := &fasthttp.Server{
		Handler:            lb.HandleRequest,
		MaxConnsPerIP:      500,
		MaxRequestsPerConn: 500,
		ReadTimeout:        10 * time.Second,
		WriteTimeout:       10 * time.Second,
		IdleTimeout:        120 * time.Second,
		TCPKeepalive:       true,
	}

	log.Printf("Load balancer starting on %s", *listenAddr)
	log.Printf("Backends: %s, %s", *socket1, *socket2)

	if err := server.ListenAndServe(*listenAddr); err != nil {
		log.Fatalf("Error starting server: %v", err)
	}
}
