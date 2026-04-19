# cavalla-bootstrap

Minimal Ubuntu bootstrap for **AWS IoT Greengrass v2**: installs the Nucleus with automatic provisioning (`--provision true`), registers an IoT Thing, and starts the `greengrass` systemd service.

This repository does **not** install Docker, clone application repos, or pull SSM secrets—only what is needed for a Thing + Greengrass Core on a fresh Ubuntu host.

## Prerequisites (AWS account)

Create (outside this script) the IoT policy, IAM role for token exchange (TES), IoT role alias, and optionally the thing group. See the [Greengrass manual installation guide](https://docs.aws.amazon.com/greengrass/v2/developerguide/manual-installation.html).

## Usage

Run as **root** and preserve environment so AWS credentials reach `sudo` (`sudo -E`).

```bash
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # plus AWS_SESSION_TOKEN if using STS
export THING_POLICY_NAME=... TES_ROLE_NAME=... TES_ROLE_ALIAS=...
sudo -E ./greengrass_bootstrap_minimal.sh my-device-01
```

Or set the thing name only via the environment:

```bash
export THING_NAME=my-device-01
sudo -E ./greengrass_bootstrap_minimal.sh
```

## Environment variables

| Variable | Description |
|----------|-------------|
| `THING_NAME` | IoT Thing name (optional positional first argument overrides). |
| `AWS_REGION` | Default: `us-east-1`. |
| `FLEET_ENV` | `dev` or `prod` — selects the shared fleet group (default: `dev`). |
| `THING_GROUP` | Override thing group name. If unset, `cavalier-${FLEET_ENV}-<last 6 digits of account>-robots` (matches CDK `DevThingGroupName` / `ProdThingGroupName`). |
| `THING_POLICY_NAME` | **Required.** Existing IoT policy attached to the core certificate. |
| `TES_ROLE_NAME` | **Required.** IAM role name for Greengrass token exchange. |
| `TES_ROLE_ALIAS` | **Required.** Existing IoT role alias for that IAM role. |
| `CREATE_THING_GROUP` | Set to `1` to create `THING_GROUP` if missing (needs `iot:CreateThingGroup`). |
| `DEPLOY_DEV_TOOLS` | Set to `1` to install the Greengrass CLI (default: `0`). |

Credentials: export keys as above, or use `AWS_PROFILE` with an invoking user so the script can resolve `~/.aws` (see the script’s `ensure_aws_credentials`).

## Install from GitHub (pin a tag)

Prefer a **release tag** (or commit SHA) over moving `main`:

```bash
TAG=v0.1.0   # replace with the tag you want
curl -fsSL -o greengrass_bootstrap_minimal.sh \
  "https://raw.githubusercontent.com/Cavalla-io/cavalla-bootstrap/${TAG}/greengrass_bootstrap_minimal.sh"
chmod +x greengrass_bootstrap_minimal.sh
# review the file, then run with sudo -E as above
```

## After install

- Status: `sudo systemctl status greengrass`
- Logs: `sudo tail -f /greengrass/v2/logs/greengrass.log`
- CLI (if `DEPLOY_DEV_TOOLS=1`): `sudo /greengrass/v2/bin/greengrass-cli component list`

## Security notes

- Do **not** commit AWS credentials. The script only reads them from the environment or standard AWS config paths.
- Review any remote script before executing it as root.

## License

MIT—see [LICENSE](LICENSE).
