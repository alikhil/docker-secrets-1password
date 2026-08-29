# Docker Secrets Engine provider for 1Password Connect

Resolve Docker Secrets Engine references from a self-hosted [1Password Connect](https://www.1password.dev/connect/get-started) server. Configuration contains only `se://` references; the provider fetches the secret value from Connect when Docker starts the workload.

Docker is tracking built-in 1Password backend support in [docker/secrets-engine#534](https://github.com/docker/secrets-engine/issues/534), but that integration is still in progress. This independent plugin fills the gap for self-hosted 1Password Connect servers today.

## What it does

The provider owns the `op/**` Secrets Engine realm and resolves exact references in this form:

```text
se://op/<vault>/<item>[/<field>]
```

`vault` and `item` are 1Password vault and item titles or UUIDs. `field` is a field label and may use the 1Password section selector form, `section.field`.

When `field` is omitted, the provider uses the item’s password-purpose field. If there is no such field, the item must contain exactly one non-empty value field. Supplying the field is recommended: it makes the selected value explicit and avoids ambiguity as an item evolves.

Wildcards are intentionally not expanded. Enumerating all accessible vaults or items merely to resolve a pattern exposes unnecessary metadata and can be unexpectedly expensive.

## Prerequisites

- [Docker Engine (CE) 29.2.0 or later](https://docs.docker.com/reference/cli/docker/pass/#installation). Docker Secrets Engine's standalone packages require this minimum Engine version.
- Ubuntu 24.04 or later, or Debian 12 or later, with systemd 250+. Ubuntu 22.04 is intentionally unsupported because its systemd 249 release does not provide `systemd-creds` or encrypted service credentials.
- Docker Secrets Engine installed and running for the user who will run this plugin.
- A [1Password Connect server](https://www.1password.dev/connect/get-started#1password-cli) already installed, running, and reachable from the host where this provider runs.
- A Connect API token scoped only to the vaults this plugin needs.
- Access to those vaults; 1Password Connect cannot access built-in Personal, Private, Employee, or default Shared vaults.

Docker Secrets Engine support on Docker CE is currently experimental and may change between releases. Review Docker's [known limitations and current guidance](https://github.com/docker/secrets-engine#docker-ce-experimental) before relying on it for a production workload.

## Install on Debian or Ubuntu

### Interactive installer

Download and inspect the installer, then run it as the non-root user whose containers will use Docker Secrets Engine:

```sh
curl -fLO https://raw.githubusercontent.com/alikhil/docker-secrets-1password/main/scripts/install.sh
less install.sh
chmod +x install.sh
./install.sh
```

For a fresh installation, the installer first confirms that a [1Password Connect server is installed](https://www.1password.dev/connect/get-started#1password-cli), running, and reachable from the host. On a rerun, it detects the existing provider and service first, reuses the configured Connect URL, and verifies that URL instead of repeating the prerequisite question. It then checks the operating system, architecture, systemd credential support, Docker access, and the Docker Engine version before changing the host. It can configure Docker's official APT repository, install Docker CE when absent, install Docker Secrets Engine and this provider from published packages, verify the provider package checksum, encrypt the Connect token, create the systemd service, enable lingering, and confirm that the plugin registered successfully. Existing encrypted credentials are preserved unless you explicitly choose to replace them.

If you need a Connect API token, create one before the credential step. Limit it to only the vaults the provider needs:

```sh
op connect token create <tokenName> --server <serverName|serverID> --vault <vaultName|vaultID>
```

Successful command output is suppressed so package-manager logs do not overwhelm the interactive prompts. If a command fails, the installer prints its last 15 output lines in a visually subdued style when the terminal supports it.

The installer supports Ubuntu 24.04+ and Debian 12+ on `amd64` and `arm64`, and requires systemd 250 or later. It does not support Ubuntu 22.04 and will stop during prerequisite checks without changing the service configuration. Run it directly rather than piping it into a shell: it is interactive and asks you to review the selected user, provider version, Connect URL, and credential location before installation.

### Manual installation

See [Manual installation](docs/manual-installation.md) for package installation, encrypted credential creation, and complete systemd service configuration.

## Upgrade

Reuse the interactive installation script to upgrade an existing installation. Download the current script and run it as the same non-root user that owns the Docker Secrets Engine service:

```sh
curl -fLO https://raw.githubusercontent.com/alikhil/docker-secrets-1password/main/scripts/install.sh
chmod +x install.sh
./install.sh
```

The installer detects the installed provider version, defaults to the latest published release, and upgrades the package when needed. It preserves the encrypted Connect credential unless you choose to replace it, refreshes the systemd unit, restarts the services, and verifies provider registration. If the selected version is already installed, the package download is skipped and only the service configuration is refreshed. Downgrades require explicit confirmation.

## Development-only foreground run

Outside systemd, point the provider at a token file:

```sh
export OP_CONNECT_HOST="https://connect.example.internal"
export OP_CONNECT_TOKEN_FILE="$HOME/.config/docker-secrets-1password/op-connect-token"
```

Start the provider in the same user session as Docker Secrets Engine:

```sh
docker-secrets-1password
```

`OP_CONNECT_TOKEN_FILE` takes precedence over the automatic systemd credential lookup. `OP_CONNECT_TOKEN` remains available as a development-only fallback, but persistent services should use the encrypted systemd credential above.

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
