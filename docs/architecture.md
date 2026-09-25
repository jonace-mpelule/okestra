# Architecture and trust model

## Goal

Okestra moves Docker's compute and storage from a developer computer to one reachable Linux server while preserving the short feedback loop of a local CLI. It is a remote development tool, not a deployment orchestrator.

## Connectivity

The developer computer initiates every connection. The server exposes one TCP listener carrying HTTP commands and WebSocket streams. No inbound listener is opened on the developer computer beyond loopback-only forwarded ports.

Okestra assumes that routing already exists between the two machines. That route may come from an encrypted mesh network, a site VPN, or a trusted local network. The application contains no vendor-specific discovery, identity, or networking logic.

With an encrypted private overlay, HTTP inside that overlay is a practical initial transport. On a network without transport encryption, place `okestra-service` behind HTTPS. Public unauthenticated exposure is outside the design boundary.

## Authentication and authorization

The current single-developer model uses one random 256-bit bearer token. The token is generated on the server, stored in a root-owned environment file, and copied once into the developer's mode-`0600` profile. All management HTTP routes and WebSocket upgrades require it. Only the liveness endpoint is public.

Possession of the token grants full control over the connected Docker Engine. This is intentionally equivalent to access to the Docker socket and must be treated as root-equivalent authority. A later multi-user version would require per-user credentials, scoped authorization, revocation, and audit history rather than extending the shared-token model.

## Runtime flow

### Build

1. The CLI validates the build directory and Dockerfile.
2. It streams a tar archive while applying `.dockerignore` rules.
3. The service stores the upload in its private work directory.
4. The service invokes `docker build` with the uploaded archive on standard input.
5. Build output is returned as WebSocket events and the temporary archive is removed.

### Container commands

Container and image operations are authenticated HTTP requests. Logs and exec sessions upgrade to WebSockets so output can be streamed and interactive bytes can travel in both directions.

### Port forwarding

The CLI binds `127.0.0.1:LOCAL_PORT`. For each local connection it opens an authenticated WebSocket to the service. The service resolves the container's private Docker-network address and bridges bytes to `CONTAINER_IP:REMOTE_PORT`. No container port needs to be published on the server host.

## State ownership

- Docker owns durable image and container state.
- `~/.okestra/config.json` owns local server profiles and tokens.
- `/etc/okestra/okestra.env` owns server configuration and its token.
- `/var/lib/okestra` contains temporary build uploads.
- Operations, exec reservations, and tunnel reservations are bounded in-memory state and reset when the service restarts.

## Current product boundary

The first usable release optimizes for one trusted developer and one server. Compose, local-directory synchronization, multi-user authorization, persistent operation history, and a graphical control plane are follow-on capabilities. The protocol already separates the CLI from the service so a desktop application can later use the same service API without changing the networking model.
