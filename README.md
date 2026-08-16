# Docker Secrets Engine provider for 1Password Connect

Resolve Docker Secrets Engine references from a self-hosted [1Password Connect](https://www.1password.dev/connect/get-started) server. Configuration contains only `se://` references; the provider fetches the secret value from Connect when Docker starts the workload.

## What it does

The provider owns the `op/**` Secrets Engine realm and resolves exact references in this form:

```text
se://op/<vault>/<item>[/<field>]
```

`vault` and `item` are 1Password vault and item titles or UUIDs. `field` is a field label and may use the 1Password section selector form, `section.field`.

When `field` is omitted, the provider uses the item’s password-purpose field. If there is no such field, the item must contain exactly one non-empty value field. Supplying the field is recommended: it makes the selected value explicit and avoids ambiguity as an item evolves.

Wildcards are intentionally not expanded. Enumerating all accessible vaults or items merely to resolve a pattern exposes unnecessary metadata and can be unexpectedly expensive.

## Prerequisites

- Docker Secrets Engine installed and running for the user who will run this plugin.
- A 1Password Connect server and a Connect API token scoped only to the vaults this plugin needs.
- Access to those vaults; 1Password Connect cannot access built-in Personal, Private, Employee, or default Shared vaults.

## Install on Debian or Ubuntu

Install Docker Secrets Engine and its plugin package from Docker’s official repository if they are not already installed:

```sh
sudo apt-get update
sudo apt-get install docker-secrets-engine docker-secrets-engine-plugins
systemctl --user daemon-reload
systemctl --user enable --now docker-secrets-engine.service
```

Download the `.deb` matching a published release and your architecture (`amd64` or `arm64`), then install it with APT:

```sh
VERSION=0.1.0
ARCH="$(dpkg --print-architecture)"
curl -fLO "https://github.com/alikhil/docker-secrets-1password/releases/download/v${VERSION}/docker-secrets-1password_${VERSION}_${ARCH}.deb"
sudo apt install "./docker-secrets-1password_${VERSION}_${ARCH}.deb"
```

The package installs `docker-secrets-1password` in `/usr/bin`. Releases also include tarballs for Linux and macOS. To build from source instead, install Go 1.25.12 or later and run:

```sh
go install github.com/alikhil/docker-secrets-1password/cmd/docker-secrets-1password@latest
```

## Configure and run

The official Connect SDK reads these variables:

```sh
export OP_CONNECT_HOST="https://connect.example.internal"
export OP_CONNECT_TOKEN="replace-with-a-vault-scoped-connect-token"
```

Start the provider in the same user session as Docker Secrets Engine:

```sh
docker-secrets-1password
```

For a persistent user service, put the two variables in a user-readable environment file and reference that file from a systemd user unit. Keep the token file owned by the service user and mode `0600`; do not commit it or place it in Compose files.

The provider registers with the Secrets Engine when it starts and exits when Docker shuts it down. Its release version is logged at startup.

## Use references

For a `production` vault item named `api-token` with a `credential` field:

```yaml
services:
  app:
    image: example/app
    environment:
      API_TOKEN: se://op/production/api-token/credential
```

An item title or field label containing `/` cannot be represented in this reference format; use the corresponding 1Password UUID instead. An empty field is treated as missing to prevent silently injecting an unintended empty value.

## Development and releases

```sh
go test ./...
go vet ./...
make lint
docker build -t docker-secrets-1password:dev .
```

Use [Conventional Commits](https://www.conventionalcommits.org/) for every change. Commitizen validates commit messages via pre-commit and performs release bookkeeping:

```sh
uvx commitizen check --rev-range HEAD~1..HEAD
uvx commitizen bump
```

`cz bump` updates the project version, this changelog, and creates a `vX.Y.Z` tag. Pushing that tag runs GoReleaser, which publishes checksummed archives and Debian packages as a GitHub Release.

## Security

Use a Connect token with the narrowest vault scope possible. The provider never writes secret values to disk or logs them, but Connect responses necessarily pass through the Docker Secrets Engine process and are injected into the target container. Treat access to the provider process and its Connect token as privileged.

To report a vulnerability, do not open a public issue. Contact the repository owner privately through GitHub.

## License

This project is licensed under [Apache License 2.0](LICENSE). Apache-2.0 is a permissive license with an explicit patent grant and aligns with Docker Secrets Engine’s Apache-2.0 license; the 1Password Connect Go SDK is MIT licensed. This project is independent and is not affiliated with Docker or 1Password.
