.PHONY: build test lint release-snapshot image

build:
	go build ./cmd/docker-secrets-1password

test:
	go test ./...

lint:
	golangci-lint run

release-snapshot:
	goreleaser release --snapshot --clean

image:
	docker build -t docker-secrets-1password:dev .
