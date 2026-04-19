# cavalla-bootstrap

Public **Greengrass bootstrap** for Cavalla edge hosts — **one script**: [`greengrass_bootstrap.sh`](greengrass_bootstrap.sh).

## Modes

| Mode | Command |
|------|---------|
| **Minimal** (Docker + Greengrass Thing/Core only) | `sudo -E ./greengrass_bootstrap.sh <thing-name>` |
| **Full Cavalier robot** (Jetson-style host, InfraStack outputs, SSM deploy key, `cavalier_system` clone, ECR cron, `/etc/cavalier/bootstrap.json`) | `sudo -E ./greengrass_bootstrap.sh --full-cavalier-robot <thing-name> [--stage dev\|prod] [--region …] [--skip-tailscale]` |

Full mode is the former `robot_setup.sh` logic, inlined into this file.

Equivalent for full without the flag: `CAVALIER_FULL_ROBOT_BOOTSTRAP=1 sudo -E ./greengrass_bootstrap.sh <thing-name> …`

### Prerequisites (AWS)

Deploy **Cavalier InfraStack** (CDK). For **full** mode, store the GitHub deploy key in SSM at `/cavalier/<stage>/deploy-ssh-key` (see Cavalla `cavalier_system` infra docs).

### Install from GitHub (pin a tag)

```bash
TAG=v0.1.0   # use a real release tag in production
curl -fsSL -o greengrass_bootstrap.sh \
  "https://raw.githubusercontent.com/Cavalla-io/cavalla-bootstrap/${TAG}/greengrass_bootstrap.sh"
chmod +x greengrass_bootstrap.sh
# review the script, then on the robot:
export AWS_PROFILE=your-profile   # or temporary keys
sudo -E ./greengrass_bootstrap.sh --full-cavalier-robot my-robot-thing --stage dev
```

### Backward compatibility

[`greengrass_bootstrap_minimal.sh`](greengrass_bootstrap_minimal.sh) is a thin `exec` wrapper to `greengrass_bootstrap.sh` so old `curl` URLs and playbooks keep working.

---

## Minimal path (details)

Installs **AWS IoT Greengrass v2** with automatic provisioning, **Docker Engine** ([get.docker.com](https://get.docker.com)), and starts `greengrass`. Defaults match Cavalla InfraStack CDK naming (`cavalier-${FLEET_ENV}-<account6>-robots`, etc.); use `FLEET_ENV=prod` for prod.

See the [Greengrass manual installation guide](https://docs.aws.amazon.com/greengrass/v2/developerguide/manual-installation.html).

### Environment variables (minimal section of the script)

| Variable | Description |
|----------|-------------|
| `THING_NAME` | IoT Thing name (positional first argument overrides). |
| `AWS_REGION` | Default: `us-east-1`. |
| `FLEET_ENV` | `dev` or `prod` (default: `dev`). |
| `THING_GROUP` | Override thing group. |
| `THING_POLICY_NAME` | Override IoT policy for the core cert. |
| `TES_ROLE_NAME` | Override IAM role for token exchange. |
| `TES_ROLE_ALIAS` | Override IoT role alias. |
| `CREATE_THING_GROUP` | Set to `1` to create `THING_GROUP` if missing. |
| `DEPLOY_DEV_TOOLS` | Set to `0` to skip local Greengrass CLI (default: `1`). |
| `SKIP_DOCKER` | Set to `1` to skip Docker (default: `0`). |
| `GREENGRASS_NUCLEUS_VERSION` | Pinned nucleus zip (default: `2.17.0`). |
| `GREENGRASS_NUCLEUS_ZIP_URL` | Override nucleus zip URL. |

Full mode adds **`STAGE`**, **`CDK_STACK_NAME`**, **`SKIP_TAILSCALE`**, **`CAVALIER_DEPLOY_USER`**, etc.; see the script header and inline comments.

---

## After install

- Status: `sudo systemctl status greengrass`
- Logs: `sudo tail -f /greengrass/v2/logs/greengrass.log`
- CLI (unless disabled): `sudo /greengrass/v2/bin/greengrass-cli component list`

## Security notes

- Do **not** commit AWS credentials. Scripts read credentials from the environment or standard AWS config paths.
- Review any remote script before executing it as root.

## License

MIT—see [LICENSE](LICENSE).
