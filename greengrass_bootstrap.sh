#!/usr/bin/env bash
# greengrass_bootstrap.sh
# Single Cavalla Greengrass bootstrap: minimal (Docker + Thing/Core) or full Jetson robot.
# https://github.com/Cavalla-io/cavalla-bootstrap
#
# Minimal (default) — Greengrass + Docker only, FLEET_ENV naming:
#   sudo -E ./greengrass_bootstrap.sh <thing-name>
#   export THING_NAME=... && sudo -E ./greengrass_bootstrap.sh
#
# Full Cavalier robot — JDK/toolchain, Tailscale optional, InfraStack outputs, SSM deploy key,
# git clone cavalier_system for ggc_user, ECR cron, /etc/cavalier/bootstrap.json:
#   sudo -E ./greengrass_bootstrap.sh --full-cavalier-robot <thing-name> [--stage dev|prod] [--region ...] [--skip-tailscale]
#   CAVALIER_FULL_ROBOT_BOOTSTRAP=1 sudo -E ./greengrass_bootstrap.sh <thing-name> ...
#
# greengrass_bootstrap_minimal.sh in this repo is a thin wrapper that calls this file (backward compatible).
#
# Minimal env: THING_NAME, AWS_REGION, FLEET_ENV, THING_GROUP, THING_POLICY_NAME, TES_ROLE_*, CREATE_THING_GROUP,
#   DEPLOY_DEV_TOOLS, SKIP_DOCKER, GREENGRASS_NUCLEUS_* (see comments in minimal section below).
#
# One-time cloud: deploy Cavalla InfraStack. See AWS Greengrass manual install docs.


set -euo pipefail

_full_robot=0
if [[ "${1:-}" == "--full-cavalier-robot" ]]; then
  shift
  _full_robot=1
elif [[ "${CAVALIER_FULL_ROBOT_BOOTSTRAP:-}" == "1" ]]; then
  _full_robot=1
fi

if [[ "${_full_robot}" == "1" ]]; then

THING_NAME="${1:-cavalier-robot-001}"
shift || true

AWS_REGION="${AWS_REGION:-us-east-1}"
STAGE="${STAGE:-dev}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
THING_GROUP="${THING_GROUP:-}"
THING_POLICY_NAME="${THING_POLICY_NAME:-}"
TES_ROLE_ALIAS="${TES_ROLE_ALIAS:-}"
TES_ROLE_NAME="${TES_ROLE_NAME:-}"
ALLOW_TES_ROLE_AUTOCREATE="${ALLOW_TES_ROLE_AUTOCREATE:-false}"
CDK_STACK_NAME="${CDK_STACK_NAME:-InfraStack}"
SKIP_TAILSCALE="${SKIP_TAILSCALE:-0}"
CAVALIER_DEPLOY_USER="${CAVALIER_DEPLOY_USER:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2 ;;
    --region) AWS_REGION="$2"; shift 2 ;;
    --skip-tailscale) SKIP_TAILSCALE=1; shift ;;
    *) echo "Unknown option: $1" >&2; shift ;;
  esac
done

BOOTSTRAP_DIR="/etc/cavalier"
BOOTSTRAP_FILE="${BOOTSTRAP_DIR}/bootstrap.json"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (example: sudo -E ./greengrass_bootstrap.sh --full-cavalier-robot <thing-name>)."
  exit 1
fi

deploy_user() {
  if [[ -n "${CAVALIER_DEPLOY_USER}" ]]; then
    echo "${CAVALIER_DEPLOY_USER}"
  elif [[ -n "${SUDO_USER:-}" ]]; then
    echo "${SUDO_USER}"
  else
    echo "ggc_user"
  fi
}

# ---------------------------------------------------------------------------
# AWS credentials
# ---------------------------------------------------------------------------

robot_ensure_aws_credentials() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${AWS_PROFILE:-}" && -n "${SUDO_USER:-}" ]]; then
    local invoking_home
    invoking_home="$(eval echo "~${SUDO_USER}")"
    if [[ -n "${invoking_home}" && "${invoking_home}" != "~${SUDO_USER}" ]]; then
      AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-${invoking_home}/.aws/config}"
      AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-${invoking_home}/.aws/credentials}"
      export AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
    fi

    echo "--- Resolving temporary credentials from profile '${AWS_PROFILE}' ---"
    local exported_creds
    if exported_creds="$(sudo -u "${SUDO_USER}" -E aws configure export-credentials \
      --profile "${AWS_PROFILE}" --format env 2>/dev/null)"; then
      eval "${exported_creds}"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      return 0
    fi
  fi

  if aws sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
    return 0
  fi

  cat <<'EOF'
Unable to obtain AWS credentials for Greengrass provisioning.

Provide one of the following before rerunning:
  1) Export temporary credentials:
     eval "$(aws configure export-credentials --profile <profile> --format env)"
  2) Or pass static credentials:
     AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN

If using sudo, preserve env vars:
  sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_SESSION_TOKEN,AWS_REGION,AWS_ACCOUNT_ID ...
EOF
  exit 1
}

resolve_stack_output() {
  local output_key="$1"
  aws cloudformation describe-stacks \
    --region "${AWS_REGION}" \
    --stack-name "${CDK_STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
    --output text 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Phase 1a: Host prerequisites
# ---------------------------------------------------------------------------

echo "=== Phase 1: Installing host prerequisites ==="

echo "--- Installing base packages ---"
apt-get update -y
apt-get install -y \
  default-jdk curl unzip cron ca-certificates \
  python3 python3-pip python3-venv \
  can-utils iproute2 \
  git build-essential pkg-config libssl-dev \
  jq

if ! command -v aws >/dev/null 2>&1; then
  echo "--- Installing AWS CLI v2 ---"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"
  rm -rf /tmp/aws
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
else
  echo "--- AWS CLI already installed ---"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "--- Installing Docker ---"
  curl -fsSL https://get.docker.com | sh
else
  echo "--- Docker already installed ---"
fi

# NVIDIA container toolkit (verify, don't install -- comes with JetPack)
if command -v nvidia-container-cli >/dev/null 2>&1; then
  echo "--- NVIDIA container toolkit present ---"
elif dpkg -l nvidia-container-toolkit >/dev/null 2>&1; then
  echo "--- NVIDIA container toolkit installed (dpkg) ---"
else
  echo "WARNING: nvidia-container-toolkit not detected. GPU containers may fail."
  echo "  Install via: apt-get install -y nvidia-container-toolkit && systemctl restart docker"
fi

# uv (Python package manager for admin API + adamo services)
_deploy_user="$(deploy_user)"
_deploy_home="$(eval echo "~${_deploy_user}")"
if ! sudo -u "${_deploy_user}" bash -lc 'command -v uv' >/dev/null 2>&1; then
  echo "--- Installing uv for ${_deploy_user} ---"
  sudo -u "${_deploy_user}" -H bash -lc \
    'curl -LsSf https://astral.sh/uv/install.sh | sh' || \
    echo "WARNING: uv install failed; admin API uv sync may fail later."
else
  echo "--- uv already installed ---"
fi

# Node.js + pnpm (for admin SPA build)
if ! command -v node >/dev/null 2>&1; then
  echo "--- Installing Node.js 20.x ---"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
else
  echo "--- Node.js already installed: $(node --version) ---"
fi
if ! command -v pnpm >/dev/null 2>&1; then
  echo "--- Installing pnpm ---"
  npm install -g pnpm || echo "WARNING: pnpm install failed; admin SPA build may fail."
else
  echo "--- pnpm already installed ---"
fi

# Rust / cargo (for adamo-network build)
if ! sudo -u "${_deploy_user}" bash -lc 'command -v cargo' >/dev/null 2>&1; then
  echo "--- Installing Rust toolchain for ${_deploy_user} ---"
  sudo -u "${_deploy_user}" -H bash -lc \
    'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y' || \
    echo "WARNING: Rust install failed; adamo-network cargo build may fail."
else
  echo "--- Rust/cargo already installed ---"
fi

# Tailscale (optional, for admin HTTPS + fleet access)
if [[ "${SKIP_TAILSCALE}" != "1" ]]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "--- Installing Tailscale ---"
    curl -fsSL https://tailscale.com/install.sh | sh || \
      echo "WARNING: Tailscale install failed; run 'curl -fsSL https://tailscale.com/install.sh | sh' manually."
  else
    echo "--- Tailscale already installed ---"
  fi
else
  echo "--- Skipping Tailscale install (--skip-tailscale) ---"
fi

# ---------------------------------------------------------------------------
# Phase 1b: Greengrass user and groups
# ---------------------------------------------------------------------------

echo "--- Configuring Greengrass user/group ---"

if ! id "ggc_user" >/dev/null 2>&1; then
  useradd --system --create-home ggc_user
fi

if ! getent group ggc_group >/dev/null 2>&1; then
  groupadd --system ggc_group
fi

usermod -aG ggc_group ggc_user || true
usermod -aG docker ggc_user || true
usermod -aG video ggc_user || true

# Ensure the deploy user is also in the docker group
if [[ "${_deploy_user}" != "ggc_user" ]]; then
  usermod -aG docker "${_deploy_user}" || true
fi

# ---------------------------------------------------------------------------
# Phase 1c: AWS credentials + resource resolution
# ---------------------------------------------------------------------------

robot_ensure_aws_credentials

if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
fi

ACCOUNT_SUFFIX=""
if [[ "${AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]]; then
  ACCOUNT_SUFFIX="${AWS_ACCOUNT_ID: -6}"
fi

# Fleet thing groups are always cavalier-dev-<account6>-robots / cavalier-prod-<account6>-robots
# (see infra_stack.py). Policy/role alias names still follow CDK stage + account suffix.
if [[ "${STAGE}" == "prod" ]]; then
  DEFAULT_THING_GROUP="cavalier-prod-robots"
else
  DEFAULT_THING_GROUP="cavalier-dev-robots"
fi
DEFAULT_THING_POLICY_NAME="CavalierGreengrassPolicy-${STAGE}"
DEFAULT_TES_ROLE_ALIAS="CavalierGreengrassRoleAlias-${STAGE}"
if [[ -n "${ACCOUNT_SUFFIX}" ]]; then
  if [[ "${STAGE}" == "prod" ]]; then
    DEFAULT_THING_GROUP="cavalier-prod-${ACCOUNT_SUFFIX}-robots"
  else
    DEFAULT_THING_GROUP="cavalier-dev-${ACCOUNT_SUFFIX}-robots"
  fi
  DEFAULT_THING_POLICY_NAME="CavalierGreengrassPolicy-${STAGE}-${ACCOUNT_SUFFIX}"
  DEFAULT_TES_ROLE_ALIAS="CavalierGreengrassRoleAlias-${STAGE}-${ACCOUNT_SUFFIX}"
fi

if [[ -z "${THING_GROUP}" ]]; then
  if [[ "${STAGE}" == "prod" ]]; then
    THING_GROUP_FROM_STACK="$(resolve_stack_output "ProdThingGroupName")"
  else
    THING_GROUP_FROM_STACK="$(resolve_stack_output "DevThingGroupName")"
  fi
  if [[ -z "${THING_GROUP_FROM_STACK}" || "${THING_GROUP_FROM_STACK}" == "None" ]]; then
    THING_GROUP_FROM_STACK="$(resolve_stack_output "ThingGroupName")"
  fi
  if [[ -n "${THING_GROUP_FROM_STACK}" && "${THING_GROUP_FROM_STACK}" != "None" ]]; then
    THING_GROUP="${THING_GROUP_FROM_STACK}"
  else
    THING_GROUP="${DEFAULT_THING_GROUP}"
  fi
fi

if [[ -z "${TES_ROLE_ALIAS}" ]]; then
  ROLE_ALIAS_FROM_STACK="$(resolve_stack_output "GreengrassRoleAliasOutput")"
  if [[ -n "${ROLE_ALIAS_FROM_STACK}" && "${ROLE_ALIAS_FROM_STACK}" != "None" ]]; then
    TES_ROLE_ALIAS="${ROLE_ALIAS_FROM_STACK}"
  else
    TES_ROLE_ALIAS="${DEFAULT_TES_ROLE_ALIAS}"
  fi
fi

if [[ -z "${THING_POLICY_NAME}" ]]; then
  THING_POLICY_NAME="${DEFAULT_THING_POLICY_NAME}"
fi

echo "=== Cavalier Greengrass Bootstrap ==="
echo "Thing name:   ${THING_NAME}"
echo "Region:       ${AWS_REGION}"
echo "Stage:        ${STAGE}"
echo "Thing group:  ${THING_GROUP}"
echo "Thing policy: ${THING_POLICY_NAME}"
echo "Role alias:   ${TES_ROLE_ALIAS}"
echo "Infra stack:  ${CDK_STACK_NAME}"
echo "Deploy user:  ${_deploy_user}"

if [[ -z "${TES_ROLE_NAME}" ]]; then
  ROLE_ARN_FROM_ALIAS="$(aws iot describe-role-alias --region "${AWS_REGION}" \
    --role-alias "${TES_ROLE_ALIAS}" \
    --query 'roleAliasDescription.roleArn' \
    --output text 2>/dev/null || true)"
  if [[ "${ROLE_ARN_FROM_ALIAS}" == arn:* ]]; then
    TES_ROLE_NAME="${ROLE_ARN_FROM_ALIAS##*/}"
  else
    if [[ "${ALLOW_TES_ROLE_AUTOCREATE}" == "true" ]]; then
      TES_ROLE_NAME="CavalierGreengrassTokenExchangeRole"
      echo "Role alias ${TES_ROLE_ALIAS} not found. Falling back to ${TES_ROLE_NAME} (autocreate enabled)."
    else
      cat <<EOF
Role alias '${TES_ROLE_ALIAS}' not found in region '${AWS_REGION}'.

Deploy infra first so bootstrap can reuse the CDK-managed TES role alias,
or set TES_ROLE_NAME explicitly if you intend to use a custom role.

To keep old behavior (autocreate role), rerun with:
  ALLOW_TES_ROLE_AUTOCREATE=true
EOF
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Phase 1d: Greengrass nucleus install + provision
# ---------------------------------------------------------------------------

if [[ -d /greengrass/v2 ]] && systemctl is-active --quiet greengrass.service 2>/dev/null; then
  echo "--- Greengrass already installed and running; skipping nucleus install ---"
  echo "  To force re-provision, stop greengrass and remove /greengrass/v2 first."
else
  echo "--- Downloading Greengrass nucleus ---"
  rm -rf /tmp/GreengrassInstaller
  GREENGRASS_NUCLEUS_VERSION="${GREENGRASS_NUCLEUS_VERSION:-2.17.0}"
  GREENGRASS_NUCLEUS_ZIP_URL="${GREENGRASS_NUCLEUS_ZIP_URL:-https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-${GREENGRASS_NUCLEUS_VERSION}.zip}"
  curl -fsSL "${GREENGRASS_NUCLEUS_ZIP_URL}" \
    -o "/tmp/greengrass-nucleus.zip"
  unzip -q /tmp/greengrass-nucleus.zip -d /tmp/GreengrassInstaller
  rm -f /tmp/greengrass-nucleus.zip

  if [[ ! -f /tmp/GreengrassInstaller/lib/Greengrass.jar ]]; then
    echo "Greengrass installer JAR not found after download."
    exit 1
  fi

  echo "--- Installing and provisioning Greengrass nucleus ---"
  java -Droot="/greengrass/v2" \
    -Dlog.store=FILE \
    -jar /tmp/GreengrassInstaller/lib/Greengrass.jar \
    --aws-region "${AWS_REGION}" \
    --thing-name "${THING_NAME}" \
    --thing-group-name "${THING_GROUP}" \
    --thing-policy-name "${THING_POLICY_NAME}" \
    --tes-role-name "${TES_ROLE_NAME}" \
    --tes-role-alias-name "${TES_ROLE_ALIAS}" \
    --component-default-user ggc_user:ggc_group \
    --provision true \
    --setup-system-service true \
    --deploy-dev-tools true

  rm -rf /tmp/GreengrassInstaller
fi

# ---------------------------------------------------------------------------
# Phase 1e: Deploy SSH key + cavalier_system repo clone
# ---------------------------------------------------------------------------

CAVALIER_REPO="/home/ggc_user/cavalier_system"
DEPLOY_SSH_KEY_PARAM="/cavalier/${STAGE}/deploy-ssh-key"

echo "=== Phase 2: Deploy key + repo clone ==="

echo "--- Fetching deploy SSH key from SSM (${DEPLOY_SSH_KEY_PARAM}) ---"
DEPLOY_KEY="$(aws ssm get-parameter --region "${AWS_REGION}" \
  --name "${DEPLOY_SSH_KEY_PARAM}" \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)"

if [[ -n "${DEPLOY_KEY}" && "${DEPLOY_KEY}" != "None" ]]; then
  sudo -u ggc_user mkdir -p /home/ggc_user/.ssh
  chmod 700 /home/ggc_user/.ssh
  chown ggc_user:ggc_group /home/ggc_user/.ssh

  echo "${DEPLOY_KEY}" > /home/ggc_user/.ssh/id_ed25519
  chown ggc_user:ggc_group /home/ggc_user/.ssh/id_ed25519
  chmod 600 /home/ggc_user/.ssh/id_ed25519

  cat <<'SSHEOF' > /home/ggc_user/.ssh/config
Host github.com
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
  User git
SSHEOF
  chown ggc_user:ggc_group /home/ggc_user/.ssh/config
  chmod 600 /home/ggc_user/.ssh/config

  echo "  [OK] Deploy SSH key configured for ggc_user"
else
  echo "WARNING: Deploy SSH key not found in SSM (${DEPLOY_SSH_KEY_PARAM})."
  echo "  Git clones in Greengrass components will fail without SSH access."
  echo "  Store the key with: aws ssm put-parameter --name ${DEPLOY_SSH_KEY_PARAM} --type SecureString --value \"\$(cat key)\""
fi

echo "--- Cloning cavalier_system repo ---"
if [[ ! -d "${CAVALIER_REPO}/.git" ]]; then
  sudo -u ggc_user git clone --recurse-submodules \
    git@github.com:Cavalla-io/cavalier_system.git "${CAVALIER_REPO}" || {
    echo "WARNING: repo clone failed. Greengrass components will attempt to sync on first deploy."
  }
else
  echo "  Repo already cloned at ${CAVALIER_REPO}; pulling latest..."
  sudo -u ggc_user git -C "${CAVALIER_REPO}" fetch --all --prune || true
  sudo -u ggc_user git -C "${CAVALIER_REPO}" pull --ff-only || true
  sudo -u ggc_user git -C "${CAVALIER_REPO}" submodule update --init --recursive || true
fi

# ---------------------------------------------------------------------------
# Phase 1f: ECR credentials refresh
# ---------------------------------------------------------------------------

echo "--- Configuring ECR credentials refresh ---"
mkdir -p /etc/greengrass
if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
  echo "Skipping ECR login setup: unable to determine AWS account ID from STS."
  echo "Set AWS_ACCOUNT_ID and rerun to enable automated ECR auth refresh."
else
  cat <<EOF >/etc/greengrass/ecr-login.sh
#!/usr/bin/env bash
set -euo pipefail
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
EOF
  chmod +x /etc/greengrass/ecr-login.sh

  cat <<EOF >/etc/cron.d/ecr-login
0 */12 * * * root /etc/greengrass/ecr-login.sh
EOF
  chmod 0644 /etc/cron.d/ecr-login
  systemctl enable cron >/dev/null 2>&1 || true
  systemctl restart cron >/dev/null 2>&1 || true

  echo "--- Initial ECR login attempt ---"
  /etc/greengrass/ecr-login.sh || echo "ECR login failed. Verify role permissions and device credentials."
fi

# ---------------------------------------------------------------------------
# Phase 1g: Write bootstrap identity file
# ---------------------------------------------------------------------------

echo "--- Writing bootstrap identity to ${BOOTSTRAP_FILE} ---"
mkdir -p "${BOOTSTRAP_DIR}"
cat <<EOF > "${BOOTSTRAP_FILE}"
{
  "thingName": "${THING_NAME}",
  "awsRegion": "${AWS_REGION}",
  "awsAccountId": "${AWS_ACCOUNT_ID}",
  "stage": "${STAGE}",
  "thingGroup": "${THING_GROUP}",
  "deployUser": "${_deploy_user}",
  "cavalierRepoRoot": "${CAVALIER_REPO}",
  "provisionedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
chmod 0644 "${BOOTSTRAP_FILE}"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo "--- Verifying Greengrass service ---"
systemctl status greengrass.service --no-pager || true

echo
echo "=== Bootstrap complete ==="
echo "Thing name:     ${THING_NAME}"
echo "Bootstrap file: ${BOOTSTRAP_FILE}"
echo "Deploy user:    ${_deploy_user}"
echo "Greengrass logs: sudo tail -f /greengrass/v2/logs/greengrass.log"
echo ""
echo "Greengrass will now receive component deployments from the CDK stack."
echo "No further manual setup is required on this device."

exit 0
fi

THING_NAME="${THING_NAME:-${1:-}}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GREENGRASS_NUCLEUS_VERSION="${GREENGRASS_NUCLEUS_VERSION:-2.17.0}"
GREENGRASS_NUCLEUS_ZIP_URL="${GREENGRASS_NUCLEUS_ZIP_URL:-https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-${GREENGRASS_NUCLEUS_VERSION}.zip}"
THING_GROUP="${THING_GROUP:-}"
FLEET_ENV="${FLEET_ENV:-dev}"
THING_POLICY_NAME="${THING_POLICY_NAME:-}"
TES_ROLE_NAME="${TES_ROLE_NAME:-}"
TES_ROLE_ALIAS="${TES_ROLE_ALIAS:-}"
CREATE_THING_GROUP="${CREATE_THING_GROUP:-0}"
DEPLOY_DEV_TOOLS="${DEPLOY_DEV_TOOLS:-1}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"

info() { echo "[gg-minimal] $*"; }
die() { echo "[gg-minimal] ERROR: $*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root, with credentials preserved, e.g.: sudo -E $0 <thing-name>"
fi

if [[ -z "${THING_NAME}" ]]; then
  die "THING_NAME is required (export THING_NAME=... or pass as first argument)."
fi

case "${FLEET_ENV}" in
  dev|prod) ;;
  *) die "FLEET_ENV must be dev or prod (got '${FLEET_ENV}')." ;;
esac

ensure_aws_credentials() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${AWS_PROFILE:-}" && -n "${SUDO_USER:-}" ]]; then
    local invoking_home
    invoking_home="$(eval echo "~${SUDO_USER}")"
    if [[ -n "${invoking_home}" && "${invoking_home}" != "~${SUDO_USER}" ]]; then
      AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-${invoking_home}/.aws/config}"
      AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-${invoking_home}/.aws/credentials}"
      export AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
    fi
    local exported
    if exported="$(sudo -u "${SUDO_USER}" -E aws configure export-credentials \
      --profile "${AWS_PROFILE}" --format env 2>/dev/null)"; then
      eval "${exported}"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      return 0
    fi
  fi

  if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity --query Account --output text >/dev/null 2>&1; then
    return 0
  fi

  die "No AWS credentials found. Use sudo -E and export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (and AWS_SESSION_TOKEN if needed), or export AWS_PROFILE=... before sudo -E."
}

# Fill THING_POLICY_NAME, TES_ROLE_ALIAS, TES_ROLE_NAME when unset — matches cavalier InfraStack CDK.
resolve_greengrass_names_from_account() {
  local acct suf resource_suffix role_arn
  acct="$(aws sts get-caller-identity --query Account --output text)"
  [[ "${#acct}" -eq 12 ]] || die "Could not read a 12-digit AWS account id from STS (got '${acct}')."
  suf="${acct: -6}"
  resource_suffix="${FLEET_ENV}-${suf}"

  if [[ -z "${THING_GROUP}" ]]; then
    THING_GROUP="cavalier-${FLEET_ENV}-${suf}-robots"
    info "Using fleet thing group '${THING_GROUP}' (FLEET_ENV=${FLEET_ENV})."
  fi

  if [[ -z "${THING_POLICY_NAME}" ]]; then
    THING_POLICY_NAME="CavalierGreengrassPolicy-${resource_suffix}"
    info "Using thing policy name '${THING_POLICY_NAME}'."
  fi
  if [[ -z "${TES_ROLE_ALIAS}" ]]; then
    TES_ROLE_ALIAS="CavalierGreengrassRoleAlias-${resource_suffix}"
    info "Using TES role alias '${TES_ROLE_ALIAS}'."
  else
    info "Using TES role alias from environment '${TES_ROLE_ALIAS}' (unset TES_ROLE_ALIAS to use CDK default for this account)."
  fi
  if [[ -z "${TES_ROLE_NAME}" ]]; then
    role_arn="$(aws iot describe-role-alias --region "${AWS_REGION}" --role-alias "${TES_ROLE_ALIAS}" \
      --query 'roleAliasDescription.roleArn' --output text 2>/dev/null || true)"
    if [[ "${role_arn}" == arn:aws:iam:* ]]; then
      TES_ROLE_NAME="${role_arn##*/}"
      info "Resolved TES IAM role name '${TES_ROLE_NAME}' from role alias."
    else
      local expected_alias="CavalierGreengrassRoleAlias-${resource_suffix}"
      if [[ "${TES_ROLE_ALIAS}" != "${expected_alias}" ]]; then
        die "IoT role alias '${TES_ROLE_ALIAS}' not found in ${AWS_REGION}. For account ${acct} the CDK default is '${expected_alias}'. Unset TES_ROLE_ALIAS and TES_ROLE_NAME (they may be from another machine), then re-run."
      fi
      die "IoT role alias '${TES_ROLE_ALIAS}' not found in ${AWS_REGION}. Deploy InfraStack (CDK) in this account/region, or set TES_ROLE_ALIAS / TES_ROLE_NAME explicitly."
    fi
  fi
}

ensure_thing_group() {
  if aws iot describe-thing-group --region "${AWS_REGION}" --thing-group-name "${THING_GROUP}" \
    >/dev/null 2>&1; then
    info "Thing group '${THING_GROUP}' already exists."
    return 0
  fi
  if [[ "${CREATE_THING_GROUP}" != "1" ]]; then
    die "Thing group '${THING_GROUP}' does not exist. Create it in IoT Core or re-run with CREATE_THING_GROUP=1."
  fi
  info "Creating thing group '${THING_GROUP}'..."
  aws iot create-thing-group --region "${AWS_REGION}" --thing-group-name "${THING_GROUP}"
}

ensure_greengrass_user() {
  if ! id "ggc_user" >/dev/null 2>&1; then
    useradd --system --create-home ggc_user
  fi
  if ! getent group ggc_group >/dev/null 2>&1; then
    groupadd --system ggc_group
  fi
  usermod -aG ggc_group ggc_user || true
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker ggc_user || true
  fi
}

install_docker() {
  if [[ "${SKIP_DOCKER}" == "1" ]]; then
    info "SKIP_DOCKER=1 — skipping Docker install."
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    info "Docker already installed ($(docker --version 2>&1))."
    return 0
  fi

  info "Installing Docker Engine (https://get.docker.com)..."
  curl -fsSL https://get.docker.com | sh

  command -v docker >/dev/null 2>&1 || die "Docker install finished but docker was not found in PATH."

  if systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
  fi

  info "Docker: $(docker --version 2>&1)"
}

install_aws_cli_v2() {
  # Ubuntu 24.04+ often has no `awscli` apt package — use the official v2 bundle.
  local arch url zip tmp
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64|arm64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *) die "Unsupported machine $(uname -m) for AWS CLI v2 bundle." ;;
  esac

  zip="$(mktemp /tmp/awscliv2-XXXXXX.zip)"
  tmp="$(mktemp -d /tmp/awscli-exe-XXXXXX)"

  info "Installing AWS CLI v2 from ${url}..."
  curl -fsSL "${url}" -o "${zip}"
  unzip -q "${zip}" -d "${tmp}"
  "${tmp}/aws/install" --update

  rm -f "${zip}"
  rm -rf "${tmp}"
}

install_prereqs() {
  export DEBIAN_FRONTEND=noninteractive
  # Recover from a half-finished apt/dpkg run (otherwise apt-get fails with
  # "dpkg was interrupted, you must manually run sudo dpkg --configure -a").
  info "Ensuring dpkg is configured (dpkg --configure -a)..."
  dpkg --configure -a || die "dpkg --configure -a failed; fix broken packages on the host, then re-run this script."

  apt-get update -y
  apt-get install -y ca-certificates curl unzip openjdk-17-jre-headless

  if ! command -v aws >/dev/null 2>&1; then
    info "Trying awscli from apt..."
    if ! apt-get install -y awscli; then
      info "apt awscli unavailable; falling back to AWS CLI v2 installer."
      install_aws_cli_v2
    fi
  fi

  command -v aws >/dev/null 2>&1 || die "AWS CLI not available after install."
  info "AWS CLI: $(aws --version 2>&1)"
}

# Subshell so EXIT cleanup runs before locals go out of scope (avoids tmp_zip unbound with set -u).
install_greengrass() (
  if [[ -d /greengrass/v2 ]] && systemctl is-active --quiet greengrass.service 2>/dev/null; then
    info "Greengrass already installed and running; skipping."
    if [[ "${DEPLOY_DEV_TOOLS}" != "0" ]]; then
      info "Local greengrass-cli is only laid down on first-time install (--deploy-dev-tools). Skipped because /greengrass/v2 already exists."
      info "For the CLI: use fleet deployment aws.greengrass.Cli when healthy, or wipe and reinstall:"
      info "  sudo systemctl stop greengrass && sudo rm -rf /greengrass/v2 && sudo -E $0 ..."
    fi
    info "To reinstall: sudo systemctl stop greengrass && sudo rm -rf /greengrass/v2 && re-run this script."
    exit 0
  fi

  tmp_zip="$(mktemp /tmp/gg-nucleus-XXXXXX.zip)"
  tmp_dir="$(mktemp -d /tmp/GreengrassInstaller-XXXXXX)"
  trap 'rm -f "${tmp_zip}"; rm -rf "${tmp_dir}"' EXIT

  info "Downloading Greengrass Nucleus ${GREENGRASS_NUCLEUS_VERSION}..."
  curl -fsSL "${GREENGRASS_NUCLEUS_ZIP_URL}" -o "${tmp_zip}"
  unzip -q "${tmp_zip}" -d "${tmp_dir}"

  jar="${tmp_dir}/lib/Greengrass.jar"
  [[ -f "${jar}" ]] || die "Greengrass.jar missing after unzip."

  dev_tools_flag="false"
  [[ "${DEPLOY_DEV_TOOLS}" == "1" ]] && dev_tools_flag="true"

  info "Installing and provisioning (Thing=${THING_NAME}, group=${THING_GROUP})..."
  java -Droot="/greengrass/v2" \
    -Dlog.store=FILE \
    -jar "${jar}" \
    --aws-region "${AWS_REGION}" \
    --thing-name "${THING_NAME}" \
    --thing-group-name "${THING_GROUP}" \
    --thing-policy-name "${THING_POLICY_NAME}" \
    --tes-role-name "${TES_ROLE_NAME}" \
    --tes-role-alias-name "${TES_ROLE_ALIAS}" \
    --component-default-user ggc_user:ggc_group \
    --provision true \
    --setup-system-service true \
    --deploy-dev-tools "${dev_tools_flag}"
)

main() {
  # Install apt packages first so `aws` exists for profile auth and thing-group checks.
  install_prereqs
  install_docker
  ensure_aws_credentials
  info "AWS account: $(aws sts get-caller-identity --query Account --output text)"
  resolve_greengrass_names_from_account
  ensure_thing_group
  ensure_greengrass_user
  install_greengrass

  echo
  info "Done. Check: sudo systemctl status greengrass"
  info "Docker (unless SKIP_DOCKER=1): sudo systemctl status docker && sudo docker run --rm hello-world"
  info "CLI (unless DEPLOY_DEV_TOOLS=0): sudo /greengrass/v2/bin/greengrass-cli component list"
  info "Logs: sudo tail -f /greengrass/v2/logs/greengrass.log"
}

main "$@"
