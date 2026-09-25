# Okestra

Okestra gives a developer a local-feeling Docker workflow while Docker Engine runs on a trusted Linux machine. The developer uses one small CLI; the server runs one small service beside Docker. Builds, logs, exec sessions, and port-forward traffic travel over a single authenticated HTTP/WebSocket endpoint.

It is designed for a private routed network such as an encrypted mesh VPN or a trusted LAN. Okestra does not depend on a particular network vendor.

## Architecture

```text
developer computer                              Linux Docker server

okestra CLI ─── authenticated HTTP/WebSocket ──► okestra-service ──► Docker Engine
     ▲                                                  │
     └──────── localhost port forwards ◄───────────────┘
```

The service needs no database and no cloud control plane. Runtime state is deliberately ephemeral; Docker remains the source of truth for images and containers.

## Supported workflow

- Stream a local build context to the server and build an image there.
- Run, list, stop, and remove remote containers.
- List remote images.
- Stream container logs.
- Run interactive and non-interactive commands in containers.
- Forward a container port back to IPv4 and IPv6 localhost on the developer computer.
- Bring up a multi-service project with a private Docker network, service-name DNS, health checks, and persistent named volumes.
- Keep project port forwards in a background local process and rebuild changed source with `watch`.
- Inspect failed containers with `why`, upgrade installed binaries, and use an optional native macOS menu-bar controller.
- Save and switch between named server profiles.
- Verify the complete connection with `okestra doctor`.

## Guided installation on your private network

Requirements:

- Linux server with Docker Engine, the Docker CLI, and systemd.
- macOS or Linux developer computer.
- Network connectivity from the developer computer to TCP port `8088` on the server.

Go 1.26 or newer is needed only if you build the packages from source. The release archives contain ready-to-run binaries.

### Quick install

On the **Linux Docker server**, run this in a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/jonace-mpelule/okestra/main/scripts/bootstrap.sh | sh -s -- server
```

Choose **1) Install or update the service** and enter the server's private-network IP with port `8088`. Keep the client URL and token shown at the end.

On the **developer Mac or Linux computer**, run:

```bash
curl -fsSL https://raw.githubusercontent.com/jonace-mpelule/okestra/main/scripts/bootstrap.sh | sh -s -- client
```

Choose **1) Install CLI and connect to a server**, then enter the URL and token from the server. The installer offers to run `okestra doctor` immediately. Both commands detect Intel/AMD64 versus ARM64, download the latest public release, check the archive's SHA-256 checksum, and open the same guided menus described below. The server command requests `sudo` only when it installs the service; the download itself runs as your regular user. Review the [bootstrap script](scripts/bootstrap.sh) before running it if you prefer not to pipe a network script into a shell.

### Manual package installation

### 1. Choose the server package

Run `uname -m` on the Linux server. Use `okestra-service_VERSION_linux_amd64.tar.gz` for `x86_64`, or `okestra-service_VERSION_linux_arm64.tar.gz` for `aarch64`, replacing `VERSION` with the published version (for example, `0.1.0`). Download the matching archive from GitHub Releases or copy it from `dist/` to the server, then extract and open its terminal menu:

```bash
tar -xzf okestra-service_0.1.0_linux_amd64.tar.gz
sudo ./install-service.sh
```

Choose **1) Install or update the service**. Enter the server's private IP address and port, such as `100.64.0.10:8088`, when prompted. The wizard creates the service account, generates a token on first install, starts the systemd service, and prints the URL and token for the client. On subsequent runs it preserves the token and lets you update the listener.

If you already have this source directory on the server, build it and open the same menu:


```bash
make VERSION=0.1.0 build
sudo ./scripts/install-service.sh ./bin/okestra-service
```

For unattended setup, use `--yes` and provide the listen address:

```bash
sudo env OKESTRA_INSTALL_ADDR=SERVER_PRIVATE_ADDRESS:8088 ./install-service.sh --yes
```

Use that command inside the extracted server archive. From a source checkout, use `sudo env OKESTRA_INSTALL_ADDR=SERVER_PRIVATE_ADDRESS:8088 ./scripts/install-service.sh --yes ./bin/okestra-service` instead.

The server menu also has **Show service status** and **Show client connection details**. Rerun `sudo ./install-service.sh` to open it again.

### 2. Choose the developer package

On the developer computer, choose the archive matching `uname -m` and the operating system from the same GitHub Release. For example, on an Apple Silicon Mac with version `0.1.0`:

```bash
tar -xzf okestra_0.1.0_darwin_arm64.tar.gz
./install-cli.sh
```

Choose **1) Install CLI and connect to a server**. Enter a profile name, the URL printed by the server wizard, and the token. The token prompt hides your input. The wizard saves a protected local profile and offers to run `okestra doctor` immediately.

From this source directory on the developer computer, the equivalent command is:

```bash
make VERSION=0.1.0 build
./scripts/install-cli.sh ./bin/okestra
```

The computer menu also offers **Install or update CLI only** and **Connect the already installed CLI**. Rerun `./install-cli.sh` to open it again.
Mac release archives also install the optional unsigned Okestra Menu app in `~/Applications`. Open it from Applications and choose your project folder. It is a local convenience controller; the CLI remains the full control plane.

For unattended installation without pairing:

```bash
./install-cli.sh --install-only
```

Both installers accept `--help` for their full command options. Install the CLI and service from the same release package version.

The server wizard listens on `0.0.0.0:8088` if no private address is entered on a first install. That reaches every server interface, so use the private address or restrict the port with the host firewall.

### 3. Verify the connection

```bash
okestra doctor
```

The profile is stored with mode `0600` in `~/.okestra/config.json`. `server` is the preferred command name; the earlier `agent` spelling remains available for compatibility.

`doctor` checks the endpoint, authentication, Docker Engine, a real minimal remote image build, build-output streaming, and a bidirectional tunnel.

### 4. Build and run the included test service

From this repository on the developer computer:

```bash
okestra build -t okestra-hello:today ./examples/hello
okestra run --name okestra-hello -p 8080:8080 okestra-hello:today
```

The second command stays open while it owns the local port forward. In another terminal:

```bash
curl http://127.0.0.1:8080
```

It should print `Okestra is working.` Press Control-C in the first terminal to close the local forward. The remote container continues running until explicitly stopped:

```bash
okestra stop okestra-hello
okestra rm okestra-hello
```

## Everyday commands

```bash
okestra status
okestra ps
okestra images
okestra rmi IMAGE
okestra logs -f CONTAINER
okestra logs --tail 100 CONTAINER
okestra exec CONTAINER uname -a
okestra exec -it CONTAINER sh
okestra port-forward CONTAINER 3000:3000
okestra build -t app:dev --build-arg NODE_ENV=development .
okestra run --name app -p 3000:3000 --env-file .env --workdir /app app:dev
okestra server list
okestra server use devbox
okestra config path
okestra why CONTAINER
okestra upgrade --check
okestra upgrade
```

Press Control-C to leave a followed log stream (`okestra logs -f`) or an interactive exec session. Without `-f`, `okestra logs` prints the existing output and exits on its own.

`--env-file` reads a local `KEY=VALUE` file and sends the values in the authenticated run request; the file itself is not copied to the server. Blank lines, comment lines, `export KEY=VALUE`, and simple quoted values are accepted. A repeated `--env KEY=VALUE` overrides the same key from the file. Keep secrets out of shell history and do not commit your real `.env`. If the container exits during startup or while a port forward is active, `okestra run` reports its status and points to `okestra logs`. A requested local port is reserved on both `127.0.0.1` and, when IPv6 is available, `::1` before the remote container is created; if either loopback address is already using it, `run` fails with an address-in-use error.

## Project workflow

Create `okestra.json` with `okestra project init`, or start from [the single-service example](examples/hello/okestra.json) or [the multi-service example](examples/multi/okestra.json). Its `services` map accepts `image` or `build` (`context`, optional `dockerfile` and `args`), `command`, `working_dir`, `env_file`, `environment`, `ports` (`LOCAL:CONTAINER`), `volumes` (`NAME:/container/path[:ro]`), `depends_on`, `restart`, and `health` (`command`, `interval_seconds`, `retries`). Paths are relative to the manifest directory. Docker service names are available to sibling containers as DNS names, such as `db` and `cache`.

From a project folder:

```bash
okestra up
okestra connect
curl http://127.0.0.1:8080
okestra project ps
okestra why okestra-okestra-hello-app
okestra disconnect
okestra down
```

`up` checks local port availability before creating remote containers. It starts existing stopped project containers; use `--build --recreate` after changing the image or environment. `connect` owns the localhost ports in a background process, so you can close the terminal; run it again to refresh changed port mappings. `connections` lists active forwards and `disconnect` closes them. `down` disconnects, removes the project's containers and private network, and **keeps named volumes**. It refuses to remove containers or networks it does not recognize as Okestra-owned.

For local source iteration, run `okestra watch` (optionally `--service app`) in a terminal. It polls the build context, applies `.dockerignore`, and rebuilds/recreates only the changed service. The first run brings the project up. It does not provide bind-mount file synchronization or hot module replacement; the container restarts after a successful rebuild. Use `connect` separately to keep localhost ports available between rebuilds. Press Control-C to stop watching.

To try the multi-service example, copy its `.env.example` to `.env`, choose a new database password, then run `okestra up` and `okestra connect` from `examples/multi`. Its public web endpoint is a smoke test; the database and cache remain private to the project network. Real apps can reach them at hostnames `db` and `cache`.

## Upgrades

After installing this version, upgrades are one command on each machine:

```bash
# Linux Docker server
sudo okestra-service upgrade

# Developer computer
okestra upgrade
```

Both commands resolve the latest public release for the current OS/CPU, verify its published SHA-256, and replace only their own binary. The server command preserves `/etc/okestra/okestra.env`, restarts the enabled systemd unit, checks that it is active, and restores the prior binary if restart fails. The Mac CLI also refreshes the bundled menu app in `~/Applications` when the archive includes it. Use `--check` to inspect the available version without installing. `update` is an alias for `upgrade`. To move from a release that predates these commands, rerun the two guided `curl` installers above once; they preserve your server token and local profiles. Upgrade the server first when the protocol version changes.

## Transport and authentication

Every management endpoint and WebSocket requires the same high-entropy bearer token. Authentication comparisons are constant-time. The unauthenticated `/healthz` endpoint reports only service liveness; Docker readiness and operational details require authentication.

Plain HTTP is acceptable when the underlying private network already supplies authenticated encryption. On an ordinary shared LAN, put the service behind an HTTPS reverse proxy. A profile can explicitly accept a private self-signed certificate with `server add --insecure-skip-verify`, but a trusted certificate is preferred.

Anyone with the Okestra token can control Docker through the service. Treat the token and access to the Docker group as root-equivalent privileges. Rotate a token by changing `OKESTRA_SERVICE_TOKEN` in `/etc/okestra/okestra.env`, restarting the service, and replacing the client profile.

## Service operations

```bash
journalctl -u okestra-service -f
sudo systemctl restart okestra-service
sudo systemctl stop okestra-service
curl http://127.0.0.1:8088/healthz
```

The service is enabled in systemd and starts after Docker on server reboot. It writes temporary uploaded build contexts under `/var/lib/okestra` and removes them after each build. It invokes the installed Docker CLI and respects `DOCKER_HOST` when configured.

## Build and verification

```bash
make test
make check
make VERSION=0.1.0 build
make VERSION=0.1.0 dist
```

`make dist` produces raw binaries and self-contained installation archives for macOS and Linux on AMD64 and ARM64, with SHA-256 checksums under `dist/`.
On macOS it also builds a universal Intel/Apple Silicon menu app and embeds it in the Mac CLI archives. `make menubar` builds just the local app. The app is unsigned, so macOS may ask you to approve its first launch; it is not yet notarized.

## Publish a GitHub Release

Once `origin` points to a GitHub repository and `gh auth status -h github.com` succeeds, publish with one command:

```bash
make release
```

The command fetches existing tags, selects the next patch version (`v0.1.0` for the first release), shows any uncommitted files and asks before committing them, runs vet and race tests, builds all six installation archives, verifies checksums, atomically pushes the branch and annotated tag, then uploads the archives and `SHA256SUMS` to a GitHub Release. It creates the release as a draft and publishes it only after the uploads succeed. It never replaces an existing tag or release asset.

For a minor or major version, use `make release RELEASE_ARGS=--minor` or `make release RELEASE_ARGS=--major`. To inspect the proposed version and files without changing anything, run `make release RELEASE_ARGS=--dry-run`. For a non-interactive run that should commit every listed repository change, add `--commit-all` to `RELEASE_ARGS`; review the file list first. If publishing fails after the tag is created, retry the same version with `make release RELEASE_ARGS="--resume vX.Y.Z"` instead of creating a new tag.

For the first release, set up an empty GitHub repository once. Authenticate with `gh auth login -h github.com`, then add its URL as `origin`. For example, if you have already created `OWNER/okestra` on GitHub without an initial README or license commit:

```bash
git remote add origin git@github.com:OWNER/okestra.git
make release
```

Choose the repository owner and visibility yourself; the release command does not create a repository or change its settings. A published release exposes source code and assets according to that repository's visibility.

## Current boundary

This release targets one trusted developer and one trusted Docker server. The project format is deliberately small and is not a full Docker Compose implementation. It does not yet include multi-user authorization, public-internet exposure, or durable operation history.

See [docs/architecture.md](docs/architecture.md) for the design and trust model, and [docs/troubleshooting.md](docs/troubleshooting.md) for connection and runtime diagnostics.
