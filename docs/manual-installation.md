# Manual installation

This guide installs Docker Secrets Engine and the 1Password Connect provider manually on a supported Debian or Ubuntu host. Review the project [prerequisites](../README.md#prerequisites) before continuing.

## Install Docker Secrets Engine

Install Docker Secrets Engine and its plugin package from Docker's official repository if they are not already installed:

```sh
sudo apt-get update
sudo apt-get install docker-secrets-engine docker-secrets-engine-plugins
systemctl --user daemon-reload
systemctl --user enable --now docker-secrets-engine.service
```

## Install the provider

Download the `.deb` matching a published release and your architecture (`amd64` or `arm64`), then install it with APT:

```sh
VERSION=0.3.2
ARCH="$(dpkg --print-architecture)"
curl -fLO "https://github.com/alikhil/docker-secrets-1password/releases/download/v${VERSION}/docker-secrets-1password_${VERSION}_${ARCH}.deb"
sudo apt install "./docker-secrets-1password_${VERSION}_${ARCH}.deb"
```

The package installs `docker-secrets-1password` in `/usr/bin`. Releases also include tarballs for Linux and macOS. To build from source instead, install Go 1.25.13 or later and run:

```sh
go install github.com/alikhil/docker-secrets-1password/cmd/docker-secrets-1password@latest
```

## Run as a system service

The provider must run for the same Linux user that runs Docker Secrets Engine. The recommended setup is a system service which decrypts the Connect token, then runs the provider as that user. The binary reads the `op-connect-token` systemd credential directly, so the token never needs to be exported into the process environment.

The steps below assume:

- Docker Secrets Engine is used by `alice` (replace it with your user name).
- 1Password Connect listens on `http://127.0.0.1:18080`. Use the internal Connect URL appropriate to your host; do not unnecessarily route a host-side provider through a public proxy.
- The Debian package was installed, so the provider binary is `/usr/bin/docker-secrets-1password`. For a tarball installation, use that binary's absolute path instead.

Enable the user service and lingering so Docker Secrets Engine survives logout and reboots:

```sh
systemctl --user enable --now docker-secrets-engine.service
sudo loginctl enable-linger alice
```

Create an encrypted systemd credential. The command prompts for the Connect API token without placing it in a shell variable or on the command line:

```sh
sudo install -d -m 0700 /etc/docker-secrets-1password
systemd-ask-password "1Password Connect API token" \
  | sudo systemd-creds encrypt --name=op-connect-token - \
    /etc/docker-secrets-1password/op-connect-token.cred
sudo chmod 0600 /etc/docker-secrets-1password/op-connect-token.cred
```

Create `/etc/systemd/system/docker-secrets-1password.service`. Replace `alice`, `/home/alice`, and `1000` with the intended user's name, home directory, and numeric UID (`id -u alice`).

```ini
[Unit]
Description=1Password Connect provider for Docker Secrets Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=alice
Group=alice
Environment=HOME=/home/alice
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=OP_CONNECT_HOST=http://127.0.0.1:18080
LoadCredentialEncrypted=op-connect-token:/etc/docker-secrets-1password/op-connect-token.cred
ExecStart=/usr/bin/docker-secrets-1password
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable it and verify registration without displaying the token:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now docker-secrets-1password.service
systemctl --user is-active docker-secrets-engine.service
sudo systemctl is-active docker-secrets-1password.service
docker pass plugins ls
```

The plugin list should show `docker-secrets-1password`, version `v…`, realm `op/**`, and status `running`. For diagnostics, inspect `sudo journalctl -u docker-secrets-1password.service` but do not use commands that print the service environment or decrypted credential.

`LoadCredentialEncrypted=` needs a system service: a user manager commonly cannot access the host credential key needed to decrypt a credential created for the system. The credential is decrypted into systemd's per-service credential directory. The provider automatically reads `$CREDENTIALS_DIRECTORY/op-connect-token`; the value is not stored in the unit, exported into the environment, or passed as a command-line argument.
