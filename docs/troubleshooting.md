# Troubleshooting

## `okestra doctor` cannot reach the endpoint

Confirm the service is listening on the server:

```bash
sudo systemctl status okestra-service
sudo ss -lntp | grep 8088
curl http://127.0.0.1:8088/healthz
```

Then test the private address from the developer computer:

```bash
curl http://SERVER_PRIVATE_ADDRESS:8088/healthz
```

If the server-local request works but the remote request fails, check the private-network route and the server firewall. Okestra does not perform NAT traversal or network discovery; it expects an already reachable private address.

## Authentication fails

Read the token on the server:

```bash
sudo sed -n 's/^OKESTRA_SERVICE_TOKEN=//p' /etc/okestra/okestra.env
```

Remove and recreate the local profile with that exact token:

```bash
okestra server remove devbox
export OKESTRA_TOKEN='<token>'
okestra server add --name devbox --url http://SERVER_PRIVATE_ADDRESS:8088
unset OKESTRA_TOKEN
```

## Service is reachable but Docker is unhealthy

The `okestra` service account must be able to access Docker:

```bash
sudo -u okestra docker version
```

For a standard Docker Engine installation, confirm that the account belongs to the `docker` group and restart the service after changing group membership:

```bash
id okestra
sudo usermod -aG docker okestra
sudo systemctl restart okestra-service
```

## A forwarded port is unavailable

Confirm that the container is running and listening on the requested container port, not only on its loopback interface:

```bash
okestra ps
okestra exec CONTAINER sh -c 'netstat -lnt 2>/dev/null || ss -lnt'
```

Also verify that the requested local port is unused. Port forwards bind IPv4 and IPv6 localhost on the developer computer. Run `okestra connections` to see Okestra-owned local forwards; `okestra disconnect` closes the current project's background forward. If the port belongs to another local app, `okestra up` fails before remote mutation.

## A project service exits immediately

Run `okestra why CONTAINER` to see its exit code, Docker health state, restart count, and recent logs. Verify `env_file` paths and required variables in `okestra.json`. `okestra up --build --recreate` applies changed environment or image configuration; a plain `up` leaves a running container unchanged.

## Upgrade says the service protocol is incompatible

Upgrade the Linux server first with `sudo okestra-service upgrade`. If it still runs an older release without that command, rerun the guided server `curl` installer in the README. It preserves the configured token and listener. Then run `okestra upgrade` on the computer and `okestra doctor`.

## Build context is unexpectedly large

Add a `.dockerignore` file to exclude `.git`, dependencies, local build output, caches, secrets, and other files that Docker does not need. Okestra streams the archive instead of retaining the whole context in client memory, but unnecessary files still consume network bandwidth and remote build time.

## Logs

Server logs are available through systemd:

```bash
journalctl -u okestra-service --since today
```

Container logs are available through Okestra:

```bash
okestra logs -f CONTAINER
```
