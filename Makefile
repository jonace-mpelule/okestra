GO ?= go
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || printf unknown)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w -X github.com/jonace-mpelule/okestra/internal/version.Version=$(VERSION) -X github.com/jonace-mpelule/okestra/internal/version.Commit=$(COMMIT) -X github.com/jonace-mpelule/okestra/internal/version.Date=$(BUILD_DATE)

.PHONY: test check build dist release clean

test:
	$(GO) test ./...

check:
	$(GO) fmt ./...
	$(GO) vet ./...
	$(GO) test -race ./...

build:
	mkdir -p bin
	$(GO) build -trimpath -ldflags '$(LDFLAGS)' -o bin/okestra ./cmd/okestra
	$(GO) build -trimpath -ldflags '$(LDFLAGS)' -o bin/okestra-service ./cmd/okestra-service

dist:
	rm -rf dist
	mkdir -p dist
	GOOS=darwin GOARCH=arm64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-darwin-arm64 ./cmd/okestra
	GOOS=darwin GOARCH=amd64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-darwin-amd64 ./cmd/okestra
	GOOS=linux GOARCH=amd64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-linux-amd64 ./cmd/okestra
	GOOS=linux GOARCH=arm64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-linux-arm64 ./cmd/okestra
	GOOS=linux GOARCH=amd64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-service-linux-amd64 ./cmd/okestra-service
	GOOS=linux GOARCH=arm64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-service-linux-arm64 ./cmd/okestra-service
	mkdir -p dist/package-cli dist/package-service
	cp scripts/install-cli.sh dist/package-cli/install-cli.sh
	cp scripts/install-service.sh deploy/systemd/okestra-service.service dist/package-service/
	cp dist/okestra-darwin-arm64 dist/package-cli/okestra
	tar -C dist/package-cli -czf dist/okestra_$(VERSION)_darwin_arm64.tar.gz .
	cp dist/okestra-darwin-amd64 dist/package-cli/okestra
	tar -C dist/package-cli -czf dist/okestra_$(VERSION)_darwin_amd64.tar.gz .
	cp dist/okestra-linux-arm64 dist/package-cli/okestra
	tar -C dist/package-cli -czf dist/okestra_$(VERSION)_linux_arm64.tar.gz .
	cp dist/okestra-linux-amd64 dist/package-cli/okestra
	tar -C dist/package-cli -czf dist/okestra_$(VERSION)_linux_amd64.tar.gz .
	cp dist/okestra-service-linux-arm64 dist/package-service/okestra-service
	tar -C dist/package-service -czf dist/okestra-service_$(VERSION)_linux_arm64.tar.gz .
	cp dist/okestra-service-linux-amd64 dist/package-service/okestra-service
	tar -C dist/package-service -czf dist/okestra-service_$(VERSION)_linux_amd64.tar.gz .
	rm -rf dist/package-cli dist/package-service
	cd dist && if command -v sha256sum >/dev/null 2>&1; then sha256sum *.tar.gz > SHA256SUMS; else shasum -a 256 *.tar.gz > SHA256SUMS; fi

release:
	./scripts/release.sh $(RELEASE_ARGS)

clean:
	rm -rf bin dist
