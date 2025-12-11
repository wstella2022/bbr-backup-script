#!/bin/sh
#
# tas_backup.sh — POSIX-compatible, production-ready TAS + OM backup script
#

# Exit on error for critical failures we don't explicitly handle
set -e

# ------------------------
# Load env
# ------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="${SCRIPT_DIR}/tas_backup.env"

if [ ! -f "${ENV_FILE}" ]; then
    printf 'ERROR: env file not found: %s\n' "${ENV_FILE}" >&2
    exit 2
fi

# shellcheck disable=SC1090
. "${ENV_FILE}"

# ------------------------
# Required env validation
# ------------------------
required_var() {
    varname="$1"
    eval val=\$"$varname" || val=
    if [ -z "${val}" ]; then
        printf 'ERROR: %s must be set in %s\n' "${varname}" "${ENV_FILE}" >&2
        exit 2
    fi
}

required_var BACKUP_DIR
required_var BOSH_TARGET
required_var BOSH_USER
required_var BOSH_CLIENT_SECRET
required_var CA_CERT

required_var OM_TARGET
required_var OM_USERNAME
required_var OM_PASSWORD

# Optional defaults (can be set in env file to override)
ROTATE_DAYS="${ROTATE_DAYS:-30}"
MAX_PARALLEL="${MAX_PARALLEL:-2}"
REQUIRED_SPACE_MB="${REQUIRED_SPACE_MB:-5000}"
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"
DEBUG="${DEBUG:-false}"

DATE="$(date +%Y%m%d_%H%M%S)"
SUMMARY_DIR="${BACKUP_DIR}/${DATE}"
SUMMARY_FILE="${SUMMARY_DIR}/precheck-summary.log"

# Lockfile & tempfiles (created later)
LOCKFILE="/var/lock/tas_backup.lock"
# if /var/lock not writable, fallback to /tmp
if [ ! -w "$(dirname "${LOCKFILE}")" ]; then
    LOCKFILE="/tmp/tas_backup.lock"
fi

# ------------------------
# Helpers
# ------------------------
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

fatal() {
    log "FATAL: $1"
    cleanup
    exit "${2:-1}"
}

cleanup() {
    # remove lock and tempfiles if exist
    if [ -n "${DEPLOYMENTS_TMP:-}" ] && [ -f "${DEPLOYMENTS_TMP}" ]; then
        rm -f "${DEPLOYMENTS_TMP}"
    fi
    if [ -n "${TAS_TILES_TMP:-}" ] && [ -f "${TAS_TILES_TMP}" ]; then
        rm -f "${TAS_TILES_TMP}"
    fi
    if [ -f "${LOCKFILE}" ]; then
        rm -f "${LOCKFILE}"
    fi
}

# ensure cleanup runs on exit
trap 'cleanup' EXIT INT TERM

# Ensure single instance
if [ -e "${LOCKFILE}" ]; then
    printf 'Another backup appears to be running (lockfile %s). Exiting.\n' "${LOCKFILE}" >&2
    exit 3
fi

# create lockfile
touch "${LOCKFILE}" || fatal "Unable to create lockfile ${LOCKFILE}"

# Verify required CLI tools exist
for cmd in bosh bbr om; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        fatal "Required command not found in PATH: ${cmd}"
    fi
done

# Check BACKUP_DIR exists (create if not)
if [ ! -d "${BACKUP_DIR}" ]; then
    mkdir -p "${BACKUP_DIR}" || fatal "Unable to create BACKUP_DIR: ${BACKUP_DIR}"
fi

# ------------------------
# Functions
# ------------------------
create_dirs() {
    mkdir -p "${SUMMARY_DIR}/bbr" "${SUMMARY_DIR}/om"
    log "Created backup directories under ${SUMMARY_DIR}"
}

rotate_old_backups() {
    log "Rotating backups older than ${ROTATE_DAYS} days (only timestamp dirs)..."
    # Only remove directories that look like timestamps (start with 20..), safer
    find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"${ROTATE_DAYS}" -exec rm -rf {} \; 2>/dev/null || true
    log "Rotation complete."
}

detect_tiles() {
    log "Detecting TAS / CF deployments via 'bosh deployments'..."

    DEPLOYMENTS_TMP="$(mktemp)" || fatal "mktemp failed"
    TAS_TILES_TMP="$(mktemp)" || fatal "mktemp failed"

    # make sure tempfiles are cleaned even if function later fails
    # trap already set for EXIT will clean them

    # Capture bosh deployments output (suppress stderr to keep tmp file clean)
    if ! bosh -e "${BOSH_TARGET}" deployments --column=name > "${DEPLOYMENTS_TMP}" 2>/dev/null; then
        fatal "Failed to run 'bosh deployments' against ${BOSH_TARGET}"
    fi

    sed -i 's/\r$//' "${DEPLOYMENTS_TMP}"

    grep -E '^(cf-[A-Za-z0-9]+|redis-enterprise-[A-Za-z0-9]+|p_spring-cloud-services-[A-Za-z0-9]+|p-healthwatch2-[A-Za-z0-9]+)' "${DEPLOYMENTS_TMP}" \
    | sort -u > "${TAS_TILES_TMP}"


    # Build space-separated list
    TAS_TILES=""
    if [ -s "${TAS_TILES_TMP}" ]; then
        # read lines into TAS_TILES separated by spaces
        while IFS= read -r line; do
            # skip empty lines
            [ -z "${line}" ] && continue
            if [ -z "${TAS_TILES}" ]; then
                TAS_TILES="${line}"
            else
                TAS_TILES="${TAS_TILES} ${line}"
            fi
        done < "${TAS_TILES_TMP}"
    fi

    if [ -z "${TAS_TILES}" ]; then
        log "No TAS/cf tiles detected."
        # leaving decision to user; in many cases we want to exit
        fatal "No tiles detected, aborting"
    fi

    log "Detected (whitelisted) tiles: ${TAS_TILES}"
    # Do not write to SUMMARY_FILE here — pre_check will initialize it and we record detected tiles there.
}

pre_check() {
    mkdir -p "$(dirname "${SUMMARY_FILE}")"
    echo "==== Pre-check summary =====" > "${SUMMARY_FILE}"
    printf "Date: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" >> "${SUMMARY_FILE}"
    printf "BOSH target: %s\n" "${BOSH_TARGET}" >> "${SUMMARY_FILE}"
    printf "Detected tiles: %s\n\n" "${TAS_TILES}" >> "${SUMMARY_FILE}"

    log "Checking BOSH director connectivity..."
    if bosh -e "${BOSH_TARGET}" env >/dev/null 2>&1; then
        log "BOSH director reachable."
        echo "BOSH director connectivity: OK" >> "${SUMMARY_FILE}"
    else
        echo "BOSH director connectivity: FAILED" >> "${SUMMARY_FILE}"
        fatal "BOSH director unreachable"
    fi

    log "Checking available disk space for ${BACKUP_DIR}..."
    AVAILABLE_SPACE_MB=$(df -Pm "${BACKUP_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    if [ -z "${AVAILABLE_SPACE_MB}" ]; then
        fatal "Unable to determine available disk space for ${BACKUP_DIR}"
    fi
    if [ "${AVAILABLE_SPACE_MB}" -ge "${REQUIRED_SPACE_MB}" ]; then
        log "Sufficient disk space: ${AVAILABLE_SPACE_MB}MB"
        echo "Disk space available: ${AVAILABLE_SPACE_MB}MB (Required: ${REQUIRED_SPACE_MB}MB) - OK" >> "${SUMMARY_FILE}"
    else
        log "Insufficient disk space: ${AVAILABLE_SPACE_MB}MB"
        echo "Disk space available: ${AVAILABLE_SPACE_MB}MB (Required: ${REQUIRED_SPACE_MB}MB) - FAILED" >> "${SUMMARY_FILE}"
        fatal "Insufficient disk space"
    fi

    # BBR pre-backup checks
    FAILED_PRECHECK_TILES=""
    for tile in ${TAS_TILES}; do
        TILE_LOG_DIR="${SUMMARY_DIR}/bbr/${tile}"
        mkdir -p "${TILE_LOG_DIR}"
        PRECHECK_LOG="${TILE_LOG_DIR}/precheck.log"

        log "Running BBR pre-backup-check for ${tile}..."
        if bbr deployment --debug --target "${BOSH_TARGET}" --username "${BOSH_USER}" --ca-cert "${CA_CERT}" --deployment "${tile}" pre-backup-check > "${PRECHECK_LOG}" 2>&1; then
            log "BBR pre-backup-check OK for ${tile}"
            echo "${tile}: pre-backup-check: OK" >> "${SUMMARY_FILE}"
        else
            log "BBR pre-backup-check FAILED for ${tile} (see ${PRECHECK_LOG})"
            echo "${tile}: pre-backup-check: FAILED (See ${PRECHECK_LOG})" >> "${SUMMARY_FILE}"
            if [ -z "${FAILED_PRECHECK_TILES}" ]; then
                FAILED_PRECHECK_TILES="${tile}"
            else
                FAILED_PRECHECK_TILES="${FAILED_PRECHECK_TILES} ${tile}"
            fi
        fi
    done

    if [ -n "${FAILED_PRECHECK_TILES}" ]; then
        log "One or more tiles failed pre-check: ${FAILED_PRECHECK_TILES}"
        # Let user decide to proceed or not
    fi

    log "Pre-checks complete. Summary at ${SUMMARY_FILE}"
}

prompt_continue() {
    if [ "${AUTO_CONFIRM}" = "true" ]; then
        log "AUTO_CONFIRM enabled; continuing without prompt."
        return 0
    fi

    printf "Pre-check finished. Continue with backup? (y/n): "
    read ans
    case "${ans}" in
        y|Y) log "User confirmed. Continuing." ;;
        *) log "Backup aborted by user."; exit 0 ;;
    esac
}

run_bbr_backup_tile() {
    tile="$1"
    TILE_DIR="${SUMMARY_DIR}/bbr/${tile}"
    mkdir -p "${TILE_DIR}"
    LOGFILE="${TILE_DIR}/bbr-backup.log"

    log "Starting BBR backup for ${tile} (logs: ${LOGFILE})"

    if bbr deployment --debug --target "${BOSH_TARGET}" \
         --username "${BOSH_USER}" \
         --ca-cert "${CA_CERT}" \
         --deployment "${tile}" \
         backup --artifact-path "${TILE_DIR}" > "${LOGFILE}" 2>&1; then
        log "BBR backup succeeded for ${tile}"
        echo "${tile}: BBR backup: OK" >> "${SUMMARY_FILE}"
    else
        log "BBR backup FAILED for ${tile} (see ${LOGFILE})"
        echo "${tile}: BBR backup: FAILED (See ${LOGFILE})" >> "${SUMMARY_FILE}"
        # return non-zero so caller can track failures
        return 1
    fi
    return 0
}

run_bbr_backup_parallel() {
    log "Running BBR backups in parallel (max ${MAX_PARALLEL})..."
    FAILURES=""
    count=0

    for tile in ${TAS_TILES}; do
        # start job
        run_bbr_backup_tile "${tile}" &
        pid=$!
        # store pids? We will wait after each batch
        count=$((count + 1))

        # When batch size hits MAX_PARALLEL, wait for all jobs to finish and collect status
        if [ $((count % MAX_PARALLEL)) -eq 0 ]; then
            wait
            # we cannot directly get each child's exit code after a collective wait, so rely on per-tile logs and summary lines
        fi
    done

    # final wait to ensure all background jobs finished
    wait

    # Detect failures via summary file (simple approach)
    if grep -q 'BBR backup: FAILED' "${SUMMARY_FILE}"; then
        log "One or more BBR backups failed. See ${SUMMARY_FILE}"
        return 1
    fi

    log "All BBR backups completed."
    return 0
}

# ------------------------
# Director precheck & backup (UAA client auth)
# ------------------------
bosh_director_precheck() {
    log "Running BOSH Director BBR pre-backup-check..."

    DIR_LOG="${SUMMARY_DIR}/bbr/bosh-director/precheck.log"
    mkdir -p "$(dirname "${DIR_LOG}")"

    bbr director --debug \
        --host "${BOSH_BBR_HOST}" \
        --username "${BOSH_BBR_USERNAME}" \
        --private-key-path "${BOSH_BBR_PRIVATE_KEY}" \
        pre-backup-check > "${DIR_LOG}" 2>&1

    if [ $? -eq 0 ]; then
        log "BOSH Director pre-backup-check PASSED"
        echo "BOSH Director: OK" >> "${SUMMARY_FILE}"
    else
        log "BOSH Director pre-backup-check FAILED"
        echo "BOSH Director: FAILED (See ${DIR_LOG})" >> "${SUMMARY_FILE}"
    fi
}

########################################
# BOSH Director Backup
########################################
bosh_director_backup() {
    log "Starting BBR backup for BOSH Director..."

    DIR_DIR="${SUMMARY_DIR}/bbr/bosh-director"
    mkdir -p "${DIR_DIR}"

    CMD="bbr director --debug\
        --host ${BOSH_BBR_HOST} \
        --username ${BOSH_BBR_USERNAME} \
        --private-key-path ${BOSH_BBR_PRIVATE_KEY} \
        backup \
        --artifact-path ${DIR_DIR}"

    if [ "${DEBUG}" = "true" ]; then
        CMD="${CMD} --debug"
    fi

    sh -c "${CMD}" > "${DIR_DIR}/bbr-backup.log" 2>&1

    if [ $? -eq 0 ]; then
        log 'BOSH Director backup completed successfully.'
    else
        log 'BOSH Director backup FAILED.'
    fi
}

export_om_config() {
    OM_DIR="${SUMMARY_DIR}/om"
    mkdir -p "${OM_DIR}"

    log "Exporting OM installation settings..."
    if om --target "${OM_TARGET}" --username "${OM_USERNAME}" --password "${OM_PASSWORD}" export-installation --output-file "${OM_DIR}/om-installation-settings.zip" 2> "${OM_DIR}/om-installation-settings.log"; then
        log "OM installation settings exported."
        echo "OM installation settings: OK" >> "${SUMMARY_FILE}"
    else
        log "OM installation settings export FAILED (see ${OM_DIR}/om-installation-settings.log)"
        echo "OM installation settings: FAILED (See ${OM_DIR}/om-installation-settings.log)" >> "${SUMMARY_FILE}"
        return 1
    fi

    return 0
}

completion() {
    log "Backup finished. Artifacts stored in ${SUMMARY_DIR}"
    log "Pre-check summary: ${SUMMARY_FILE}"
}

# ------------------------
# Main
# ------------------------
create_dirs
rotate_old_backups
detect_tiles

if ! bosh_director_precheck; then
    log "BOSH director pre-check failed. Consider investigating; continuing with tile backups."
fi

pre_check
prompt_continue

if ! bosh_director_backup; then
    log "BOSH director backup failed (or skipped). Continuing with tile backups."
fi


if ! run_bbr_backup_parallel; then
    log "One or more BBR backups failed. Proceeding to export OM config (but consider investigating failures)."
fi

if ! export_om_config; then
    log "OM export encountered errors. See ${SUMMARY_DIR}/om/*.log"
fi

completion
# explicit cleanup will be handled by trap
