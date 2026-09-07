#!/usr/bin/env bash
# upgrade social service from one deployed version to another

set -euo pipefail
shopt -s nullglob

script_dir=$(cd "$(dirname "$0")" || exit 1; pwd)
# shellcheck disable=SC1091
source "${script_dir}/../common/common.sh"

init_log_file "upgrade-social.log"

env_file="${script_dir}/.env"

module_name="social"
deploy_root="/opt/deploy"

usage() {
    log "Usage: $0 [current_version] [target_version]"
}

resolve_version_dir() {
    local version=$1
    local candidates=()
    local dir

    for dir in "${deploy_root}/${module_name}-"*; do
        if [[ -d "$dir" ]] && artifact_info_from_name "$module_name" "$(basename "$dir")" && [[ "$PACKAGE_VERSION" == "$version" ]]; then
            candidates+=("$(basename "$dir")")
        fi
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 1
    fi

    select_latest_named_item "$module_name" "${candidates[@]}" || return 1
    printf '%s/%s' "$deploy_root" "$SELECTED_NAME"
}

if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi

current_version=$(trim "$1")
target_version=$(trim "$2")

if [[ -z "$current_version" || -z "$target_version" ]]; then
    usage
    exit 1
fi

if [[ "$current_version" == "$target_version" ]]; then
    log "current_version equals target_version (${current_version}), skip social upgrade."
    exit 0
fi

current_dir=$(resolve_version_dir "$current_version") || {
    log "ERROR! current version directory is missing: /opt/deploy/social-v${current_version}-****"
    exit 1
}
target_dir=$(resolve_version_dir "$target_version") || {
    log "ERROR! target version directory is missing: /opt/deploy/social-v${target_version}-****"
    exit 1
}

log "current dir: ${current_dir}"
log "target dir: ${target_dir}"

if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
fi

WAIT_SECONDS=$(trim "${WAIT_SECONDS:-0}")
RETRY_TIMES=$(trim "${RETRY_TIMES:-0}")

if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    log "ERROR! invalid WAIT_SECONDS: ${WAIT_SECONDS}, expected a non-negative integer"
    exit 1
fi

if ! [[ "$RETRY_TIMES" =~ ^[0-9]+$ ]]; then
    log "ERROR! invalid RETRY_TIMES: ${RETRY_TIMES}, expected a non-negative integer"
    exit 1
fi

[[ -f "${current_dir}/scripts/starter.sh" ]] || { log "ERROR! missing script: ${current_dir}/scripts/starter.sh"; exit 1; }
[[ -f "${target_dir}/scripts/starter.sh" ]] || { log "ERROR! missing script: ${target_dir}/scripts/starter.sh"; exit 1; }
[[ -f "${current_dir}/scripts/copy-for-upgrade.sh" ]] || { log "ERROR! missing script: ${current_dir}/scripts/copy-for-upgrade.sh"; exit 1; }
[[ -d "${target_dir}/web/dist" ]] || { log "ERROR! missing web dist: ${target_dir}/web/dist"; exit 1; }

log "stop current social: cd ${current_dir} && scripts/starter.sh stop"
if ! (cd "$current_dir" && bash scripts/starter.sh stop >> "$LOGFILE" 2>&1); then
    log "ERROR! failed to stop current social service"
    exit 1
fi

log "copy files for upgrade operation: cd ${current_dir} && scripts/copy-for-upgrade.sh ${target_dir}"
if ! (cd "$current_dir" && bash scripts/copy-for-upgrade.sh ${target_dir}>> "$LOGFILE" 2>&1); then
    log "ERROR! failed to copy files for upgrade operation"
    exit 1
fi

log "publish target frontend: ${target_dir}/web/dist -> /usr/share/nginx/html/social/dist"
if ! rm -rf /usr/share/nginx/html/social/dist >> "$LOGFILE" 2>&1; then
    log "ERROR! failed to remove old social frontend dist"
    exit 1
fi
if ! mkdir -p /usr/share/nginx/html/social >> "$LOGFILE" 2>&1; then
    log "ERROR! failed to create social frontend directory"
    exit 1
fi
if ! cp -r "${target_dir}/web/dist" /usr/share/nginx/html/social/dist >> "$LOGFILE" 2>&1; then
    log "ERROR! failed to publish target social frontend"
    exit 1
fi
if ! systemctl restart nginx >> "$LOGFILE" 2>&1; then
    log "ERROR! failed to restart nginx"
    exit 1
fi

log "start target social: cd ${target_dir} && scripts/starter.sh"
if ! (cd "$target_dir" && bash scripts/starter.sh >> "$LOGFILE" 2>&1); then
    log "ERROR! failed to start target social service"
    exit 1
fi

if [[ -f "${target_dir}/scripts/health-check.sh" ]]; then
    health_check_status=0
    max_health_check_attempts=$((RETRY_TIMES + 1))

    for ((attempt = 1; attempt <= max_health_check_attempts; attempt++)); do
        if (( WAIT_SECONDS > 0 )); then
            log "wait ${WAIT_SECONDS}s before social health check attempt ${attempt}/${max_health_check_attempts}"
            sleep "$WAIT_SECONDS"
        fi

        log "health check target social attempt ${attempt}/${max_health_check_attempts}: cd ${target_dir} && scripts/health-check.sh --level all"
        if (cd "$target_dir" && bash scripts/health-check.sh --level all >> "$LOGFILE" 2>&1); then
            health_check_status=0
            break
        else
            health_check_status=$?
        fi

        log "social health check failed on attempt ${attempt}/${max_health_check_attempts} with exit code ${health_check_status}"
    done

    if [[ $health_check_status -ne 0 ]]; then
        log "ERROR! social health check failed after ${max_health_check_attempts} attempt(s)"
        exit "$health_check_status"
    fi

    log "social health check passed"
else
    log "WARN! skip social health check, script is missing: ${target_dir}/scripts/health-check.sh"
fi

log "social upgrade done: ${current_version} -> ${target_version}"
