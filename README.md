# cavalla-bootstrap

Minimal Ubuntu bootstrap for **AWS IoT Greengrass v2**: installs the Nucleus with automatic provisioning (`--provision true`), registers an IoT Thing, and starts the `greengrass` systemd service.

The script also installs **Docker Engine** (via [get.docker.com](https://get.docker.com), same approach as `robot_setup.sh`) and adds `ggc_user` to the `docker` group so container-based Greengrass components can run. It does not clone application repos or pull SSM secrets—only the host stack needed for a Thing + Core on a fresh Ubuntu host.

## Prerequisites (AWS account)

Deploy **Cavalier InfraStack** (CDK) in the target account/region so the IoT policy, TES IAM role, IoT role alias, and fleet thing groups exist with the expected names. The script defaults to the **dev** fleet and CDK naming (`CavalierGreengrassPolicy-dev-<account6>`, etc.); use `FLEET_ENV=prod` for prod. For a fully custom AWS layout, set `THING_GROUP`, `THING_POLICY_NAME`, `TES_ROLE_ALIAS`, and/or `TES_ROLE_NAME` explicitly.

See also the [Greengrass manual installation guide](https://docs.aws.amazon.com/greengrass/v2/developerguide/manual-installation.html).

## Usage

Run as **root** and preserve environment so AWS credentials reach `sudo` (`sudo -E`).

```bash
export AWS_PROFILE=your-profile   # or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY [/ AWS_SESSION_TOKEN]
sudo -E ./greengrass_bootstrap_minimal.sh my-device-01
```

Or set the thing name via the environment:

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
| `THING_GROUP` | Override thing group. Default: `cavalier-${FLEET_ENV}-<last 6 digits of account>-robots` (CDK fleet groups). |
| `THING_POLICY_NAME` | Override IoT policy for the core cert. Default: `CavalierGreengrassPolicy-${FLEET_ENV}-<account6>`. |
| `TES_ROLE_NAME` | Override IAM role name for token exchange. Default: IAM role behind `TES_ROLE_ALIAS` (from `describe-role-alias`). |
| `TES_ROLE_ALIAS` | Override IoT role alias. Default: `CavalierGreengrassRoleAlias-${FLEET_ENV}-<account6>`. |
| `CREATE_THING_GROUP` | Set to `1` to create `THING_GROUP` if missing (needs `iot:CreateThingGroup`). |
| `DEPLOY_DEV_TOOLS` | Set to `1` to install the Greengrass CLI (default: `0`). |
| `SKIP_DOCKER` | Set to `1` to skip Docker Engine install (default: `0`). |

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
