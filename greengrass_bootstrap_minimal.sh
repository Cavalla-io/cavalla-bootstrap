#!/usr/bin/env bash
# greengrass_bootstrap_minimal.sh
#
# Bare-minimum Ubuntu bootstrap: install AWS IoT Greengrass v2 Nucleus with
# automatic provisioning (--provision true), which registers this host as a
# new IoT Thing and starts the greengrass systemd service.
#
# Installs Docker Engine (same flow as cavalier robot_setup: get.docker.com) so
# Greengrass components can run container images; set SKIP_DOCKER=1 to opt out.
# Does not clone application repos or pull SSM secrets — only host + Thing + Core.
#
# Usage (preserve credentials through sudo):
#   export AWS_PROFILE=...   # or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY [/ AWS_SESSION_TOKEN]
#   sudo -E ./greengrass_bootstrap_minimal.sh my-device-01
#
# Or: export THING_NAME=my-device-01 && sudo -E ./greengrass_bootstrap_minimal.sh
#
# Defaults (after STS resolves the account) match Cavalla InfraStack CDK naming:
#   THING_GROUP        cavalier-${FLEET_ENV}-<last6(account)>-robots  (FLEET_ENV defaults to dev)
#   THING_POLICY_NAME  CavalierGreengrassPolicy-${FLEET_ENV}-<last6>
#   TES_ROLE_ALIAS     CavalierGreengrassRoleAlias-${FLEET_ENV}-<last6>
#   TES_ROLE_NAME      IAM role name behind that alias (from describe-role-alias)
# Override any of the above with env vars if your account uses different names.
#
# Environment:
#   THING_NAME           IoT Thing name (positional $1 overrides)
#   AWS_REGION           default: us-east-1
#   FLEET_ENV            dev or prod — fleet suffix for group + IoT policy/alias names (default: dev)
#   THING_GROUP          Override thing group (default: cavalier-${FLEET_ENV}-<account6>-robots)
#   THING_POLICY_NAME    Override IoT policy for the core certificate (default: CDK pattern above)
#   TES_ROLE_NAME        Override IAM role name for token exchange (default: from role alias)
#   TES_ROLE_ALIAS       Override IoT role alias (default: CDK pattern above)
#   CREATE_THING_GROUP   if set to 1, create THING_GROUP when missing (needs iot:CreateThingGroup)
#   DEPLOY_DEV_TOOLS     if set to 1, install Greengrass CLI (default: 0)
#   SKIP_DOCKER          if set to 1, skip Docker Engine install (default: 0)
#
# AWS credentials: use sudo -E with exported keys, or AWS_PROFILE (see ensure_aws_credentials).
#
# One-time cloud: deploy Cavalla InfraStack (or create equivalent IoT policy, TES role, role alias,
# and thing group). See: https://docs.aws.amazon.com/greengrass/v2/developerguide/manual-installation.html

set -euo pipefail

THING_NAME="${THING_NAME:-${1:-}}"
AWS_REGION="${AWS_REGION:-us-east-1}"
THING_GROUP="${THING_GROUP:-}"
FLEET_ENV="${FLEET_ENV:-dev}"
THING_POLICY_NAME="${THING_POLICY_NAME:-}"
TES_ROLE_NAME="${TES_ROLE_NAME:-}"
TES_ROLE_ALIAS="${TES_ROLE_ALIAS:-}"
CREATE_THING_GROUP="${CREATE_THING_GROUP:-0}"
DEPLOY_DEV_TOOLS="${DEPLOY_DEV_TOOLS:-0}"
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
  fi
  if [[ -z "${TES_ROLE_NAME}" ]]; then
    role_arn="$(aws iot describe-role-alias --region "${AWS_REGION}" --role-alias "${TES_ROLE_ALIAS}" \
      --query 'roleAliasDescription.roleArn' --output text 2>/dev/null || true)"
    if [[ "${role_arn}" == arn:aws:iam:* ]]; then
      TES_ROLE_NAME="${role_arn##*/}"
      info "Resolved TES IAM role name '${TES_ROLE_NAME}' from role alias."
    else
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

install_greengrass() {
  if [[ -d /greengrass/v2 ]] && systemctl is-active --quiet greengrass.service 2>/dev/null; then
    info "Greengrass already installed and running; skipping."
    info "To reinstall: sudo systemctl stop greengrass && sudo rm -rf /greengrass/v2 && re-run this script."
    return 0
  fi

  local tmp_zip tmp_dir
  tmp_zip="$(mktemp /tmp/gg-nucleus-XXXXXX.zip)"
  tmp_dir="$(mktemp -d /tmp/GreengrassInstaller-XXXXXX)"
  trap 'rm -f "${tmp_zip}"; rm -rf "${tmp_dir}"' EXIT

  info "Downloading Greengrass Nucleus..."
  curl -fsSL "https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip" -o "${tmp_zip}"
  unzip -q "${tmp_zip}" -d "${tmp_dir}"

  local jar="${tmp_dir}/lib/Greengrass.jar"
  [[ -f "${jar}" ]] || die "Greengrass.jar missing after unzip."

  local dev_tools_flag="false"
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
}

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
  info "CLI (if DEPLOY_DEV_TOOLS=1): sudo /greengrass/v2/bin/greengrass-cli component list"
  info "Logs: sudo tail -f /greengrass/v2/logs/greengrass.log"
}

main "$@"
