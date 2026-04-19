#!/usr/bin/env bash
# greengrass_bootstrap_minimal.sh
#
# Bare-minimum Ubuntu bootstrap: install AWS IoT Greengrass v2 Nucleus with
# automatic provisioning (--provision true), which registers this host as a
# new IoT Thing and starts the greengrass systemd service.
#
# This script does NOT install Docker, clone repos, or pull SSM secrets — only
# what is needed to get a Thing + Greengrass Core running on a fresh Ubuntu.
#
# Usage (preserve credentials through sudo):
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # and AWS_SESSION_TOKEN if using STS
#   export THING_POLICY_NAME=... TES_ROLE_NAME=... TES_ROLE_ALIAS=...
#   sudo -E ./greengrass_bootstrap_minimal.sh my-device-01
#
# Or pass everything via env and no positional arg:
#   export THING_NAME=my-device-01
#   sudo -E ./greengrass_bootstrap_minimal.sh
#
# Environment:
#   THING_NAME           IoT Thing name (positional $1 overrides)
#   AWS_REGION           default: us-east-1
#   FLEET_ENV            dev or prod — shared fleet group suffix (default: dev)
#   THING_GROUP          If unset, cavalier-${FLEET_ENV}-<account6>-robots (CDK fleet groups)
#   THING_POLICY_NAME    Name of an EXISTING IoT policy to attach to the core cert (required)
#   TES_ROLE_NAME        IAM role name used for Greengrass Token Exchange (required)
#   TES_ROLE_ALIAS       EXISTING IoT role alias for that IAM role (required)
#   CREATE_THING_GROUP   if set to 1, create THING_GROUP when missing (needs iot:CreateThingGroup)
#   DEPLOY_DEV_TOOLS     if set to 1, install Greengrass CLI (default: 0)
#
# AWS credentials: use sudo -E with exported keys, or AWS_PROFILE (see ensure_aws below).
#
# One-time cloud setup (not done by this script):
#   - Create the IoT policy, IAM TES role, and IoT role alias Greengrass expects.
#   - Create the thing group (or set CREATE_THING_GROUP=1 with creds that allow it).
#   See: https://docs.aws.amazon.com/greengrass/v2/developerguide/manual-installation.html

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

info() { echo "[gg-minimal] $*"; }
die() { echo "[gg-minimal] ERROR: $*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root, with credentials preserved, e.g.: sudo -E $0 <thing-name>"
fi

if [[ -z "${THING_NAME}" ]]; then
  die "THING_NAME is required (export THING_NAME=... or pass as first argument)."
fi

if [[ -z "${THING_POLICY_NAME}" || -z "${TES_ROLE_NAME}" || -z "${TES_ROLE_ALIAS}" ]]; then
  die "Set THING_POLICY_NAME, TES_ROLE_NAME, and TES_ROLE_ALIAS to existing AWS resources. See script header comments."
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

  die "No AWS credentials found. Export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (and AWS_SESSION_TOKEN if needed) and run: sudo -E $0 ..."
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
  ensure_aws_credentials
  info "AWS account: $(aws sts get-caller-identity --query Account --output text)"
  if [[ -z "${THING_GROUP}" ]]; then
    acct="$(aws sts get-caller-identity --query Account --output text)"
    if [[ "${#acct}" -eq 12 ]]; then
      suf="${acct: -6}"
      THING_GROUP="cavalier-${FLEET_ENV}-${suf}-robots"
    else
      die "Could not resolve AWS account for default THING_GROUP; set THING_GROUP explicitly."
    fi
    info "Using fleet thing group '${THING_GROUP}' (FLEET_ENV=${FLEET_ENV})."
  fi
  ensure_thing_group
  ensure_greengrass_user
  install_greengrass

  echo
  info "Done. Check: sudo systemctl status greengrass"
  info "CLI (if DEPLOY_DEV_TOOLS=1): sudo /greengrass/v2/bin/greengrass-cli component list"
  info "Logs: sudo tail -f /greengrass/v2/logs/greengrass.log"
}

main "$@"
