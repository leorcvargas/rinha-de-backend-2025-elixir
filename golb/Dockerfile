FROM golang:1.24-alpine AS builder

WORKDIR /app

COPY . .

RUN go get

RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o loadbalancer .

FROM alpine:3.21.4

RUN apk --no-cache add ca-certificates

WORKDIR /app/

COPY --from=builder /app/loadbalancer .

EXPOSE 80

CMD ["./loadbalancer"]
