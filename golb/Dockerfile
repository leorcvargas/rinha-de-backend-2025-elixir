FROM golang:1.24 AS builder

WORKDIR /app

COPY . .

RUN go get

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -a -o loadbalancer .

FROM docker.io/debian:bookworm-20250721-slim

WORKDIR /app/

COPY --from=builder /app/loadbalancer .

EXPOSE 80

CMD ["./loadbalancer"]
