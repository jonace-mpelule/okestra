GO ?= go
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || printf unknown)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w -X github.com/jonace-mpelule/okestra/internal/version.Version=$(VERSION) -X github.com/jonace-mpelule/okestra/internal/version.Commit=$(COMMIT) -X github.com/jonace-mpelule/okestra/internal/version.Date=$(BUILD_DATE)

.PHONY: test check build dist menubar device release clean

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
	mkdir -p dist
	@test ! -e dist/package-cli && test ! -e dist/package-service || (echo 'temporary package directory already exists; move it aside before building' >&2; exit 1)
	GOOS=darwin GOARCH=arm64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-darwin-arm64 ./cmd/okestra
	GOOS=darwin GOARCH=amd64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-darwin-amd64 ./cmd/okestra
	GOOS=linux GOARCH=amd64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-linux-amd64 ./cmd/okestra
	GOOS=linux GOARCH=arm64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-linux-arm64 ./cmd/okestra
	GOOS=linux GOARCH=amd64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-service-linux-amd64 ./cmd/okestra-service
	GOOS=linux GOARCH=arm64 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o dist/okestra-service-linux-arm64 ./cmd/okestra-service
	mkdir -p dist/package-cli/docs/archive dist/package-service/docs/archive
	cp scripts/install-cli.sh dist/package-cli/install-cli.sh
	sed 's|](expo.md)|](docs/expo.md)|g; s|](android.md)|](docs/android.md)|g; s|](archive/|](docs/archive/|g' docs/android.md > dist/package-cli/ANDROID.md
	sed 's|](expo.md)|](docs/expo.md)|g; s|](android.md)|](docs/android.md)|g; s|](archive/|](docs/archive/|g' docs/expo.md > dist/package-cli/EXPO.md
	cp docs/android.md docs/expo.md dist/package-cli/docs/
	cp docs/archive/*.md dist/package-cli/docs/archive/
	cp scripts/setup-android-mac.sh scripts/install-android.sh 'scripts/Install Android.command' dist/package-cli/
	cp scripts/install-service.sh scripts/setup-android-server.sh scripts/install-android.sh scripts/android-tools.py deploy/systemd/okestra-service.service dist/package-service/
	sed 's|](expo.md)|](docs/expo.md)|g; s|](android.md)|](docs/android.md)|g; s|](archive/|](docs/archive/|g' docs/android.md > dist/package-service/ANDROID.md
	sed 's|](expo.md)|](docs/expo.md)|g; s|](android.md)|](docs/android.md)|g; s|](archive/|](docs/archive/|g' docs/expo.md > dist/package-service/EXPO.md
	cp docs/android.md docs/expo.md dist/package-service/docs/
	cp docs/archive/*.md dist/package-service/docs/archive/
	cp dist/okestra-linux-arm64 dist/package-cli/okestra
	tar -C dist/package-cli -czf dist/okestra_$(VERSION)_linux_arm64.tar.gz .
	cp dist/okestra-linux-amd64 dist/package-cli/okestra
	tar -C dist/package-cli -czf dist/okestra_$(VERSION)_linux_amd64.tar.gz .
	@if [ "$$(uname -s)" = Darwin ]; then OKESTRA_LDFLAGS='$(LDFLAGS)' OKESTRA_VERSION=$(VERSION) ./scripts/build-device.sh && OKESTRA_LDFLAGS='$(LDFLAGS)' OKESTRA_VERSION=$(VERSION) ./scripts/build-menubar.sh && cp -R 'dist/Okestra Menu.app' 'dist/Okestra Device.app' dist/package-cli/; fi
	cp dist/okestra-darwin-arm64 dist/package-cli/okestra
	tar -C dist/package-cli -czf dist/okestra_$(VERSION)_darwin_arm64.tar.gz .
	cp dist/okestra-darwin-amd64 dist/package-cli/okestra
	tar -C dist/package-cli -czf dist/okestra_$(VERSION)_darwin_amd64.tar.gz .
	cp dist/okestra-service-linux-arm64 dist/package-service/okestra-service
	tar -C dist/package-service -czf dist/okestra-service_$(VERSION)_linux_arm64.tar.gz .
	cp dist/okestra-service-linux-amd64 dist/package-service/okestra-service
	tar -C dist/package-service -czf dist/okestra-service_$(VERSION)_linux_amd64.tar.gz .
	rm -rf dist/package-cli dist/package-service
	cd dist && if command -v sha256sum >/dev/null 2>&1; then sha256sum okestra_$(VERSION)_*.tar.gz okestra-service_$(VERSION)_*.tar.gz > SHA256SUMS; else shasum -a 256 okestra_$(VERSION)_*.tar.gz okestra-service_$(VERSION)_*.tar.gz > SHA256SUMS; fi

release:
	./scripts/release.sh $(RELEASE_ARGS)

clean:
	rm -rf bin dist

menubar:
	./scripts/build-menubar.sh

device:
	./scripts/build-device.sh
