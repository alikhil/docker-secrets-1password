.PHONY: build test test-installer lint release-snapshot image

build:
	go build ./cmd/docker-secrets-1password

test:
	go test ./...
	bash scripts/install_test.sh

test-installer:
	bash -n scripts/install.sh scripts/install_test.sh
	shellcheck scripts/install.sh scripts/install_test.sh
	bash scripts/install_test.sh

lint:
	golangci-lint run

release-snapshot:
	goreleaser release --snapshot --clean

image:
	docker build -t docker-secrets-1password:dev .
