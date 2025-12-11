#!/bin/sh

########################################
# TAS + OM Backup Script (POSIX version)
########################################

# Load environment variables
SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/tas_backup.env"

DATE=$(date +%Y%m%d_%H%M%S)
MAX_PARALLEL=3

SUMMARY_DIR="${BACKUP_DIR}/${DATE}"
SUMMARY_FILE="${SUMMARY_DIR}/precheck-summary.log"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

create_dirs() {
    mkdir -p "${SUMMARY_DIR}/bbr" "${SUMMARY_DIR}/om"
    log "Created backup directories under ${SUMMARY_DIR}"
}

rotate_old_backups() {
    log "Rotating backups older than ${ROTATE_DAYS} days..."
    find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +"${ROTATE_DAYS}" -exec rm -rf {} \;
}

########################################
# Detect TAS / CF tiles (POSIX version)
########################################
detect_tiles() {
    log "Detecting TAS tiles from BOSH deployments..."

    # Run bosh deployments and extract names starting with p- or cf
    DEPLOYMENTS_TMP=$(mktemp)
    bosh -e "${BOSH_TARGET}" deployments > "${DEPLOYMENTS_TMP}" 2>/dev/null

    TAS_TILES_TMP=$(mktemp)
    grep -E '^(p-|cf)' "${DEPLOYMENTS_TMP}" | awk '{print $1}' | sort -u > "${TAS_TILES_TMP}"

    # Load into space-separated string
    TAS_TILES=$(tr '\n' ' ' < "${TAS_TILES_TMP}")

    rm -f "${DEPLOYMENTS_TMP}" "${TAS_TILES_TMP}"

    if [ -z "${TAS_TILES}" ]; then
        log "No TAS/cf tiles detected. Exiting."
        exit 1
    fi

    log "Detected tiles: ${TAS_TILES}"
    echo "Detected tiles: ${TAS_TILES}" >> "${SUMMARY_FILE}"
}

########################################
# Pre-checks
########################################
pre_check() {
    mkdir -p "$(dirname "${SUMMARY_FILE}")"
    echo "==== Pre-check summary =====" > "${SUMMARY_FILE}"

    log "Checking BOSH director connectivity..."
    if bosh -e "${BOSH_TARGET}" env >/dev/null 2>&1; then
        log "BOSH director reachable."
        echo "BOSH director connectivity: OK" >> "${SUMMARY_FILE}"
    else
        log "BOSH director UNREACHABLE!"
        echo "BOSH director connectivity: FAILED" >> "${SUMMARY_FILE}"
        exit 1
    fi

    # Disk space check
    REQUIRED_SPACE_MB=5000
    AVAILABLE_SPACE_MB=$(df -Pm "${BACKUP_DIR}" | tail -1 | awk '{print $4}')

    if [ "${AVAILABLE_SPACE_MB}" -ge "${REQUIRED_SPACE_MB}" ]; then
        log "Sufficient disk space: ${AVAILABLE_SPACE_MB}MB"
        echo "Disk space available: ${AVAILABLE_SPACE_MB}MB - OK" >> "${SUMMARY_FILE}"
    else
        log "Insufficient disk space: ${AVAILABLE_SPACE_MB}MB"
        echo "Disk space available: ${AVAILABLE_SPACE_MB}MB - FAILED" >> "${SUMMARY_FILE}"
        exit 1
    fi

    # BBR pre-backup-check
    for tile in ${TAS_TILES}; do
        TILE_LOG="${SUMMARY_DIR}/bbr/${tile}/precheck.log"
        mkdir -p "$(dirname "${TILE_LOG}")"

        log "Running BBR pre-backup-check for ${tile}..."
        bbr deployment --target "${BOSH_TARGET}" \
            --username "${BOSH_USER}" \
            --private-key-path "${PRIVATE_KEY_PATH}" \
            --deployment "${tile}" \
            pre-backup-check > "${TILE_LOG}" 2>&1

        if [ $? -eq 0 ]; then
            log "BBR pre-backup-check passed for ${tile}"
            echo "${tile}: OK" >> "${SUMMARY_FILE}"
        else
            log "BBR pre-backup-check FAILED for ${tile}"
            echo "${tile}: FAILED (See ${TILE_LOG})" >> "${SUMMARY_FILE}"
        fi
    done

    log "Pre-check completed. Summary written to ${SUMMARY_FILE}"
}

prompt_continue() {
    if [ "${AUTO_CONFIRM}" = "true" ]; then
        log "AUTO_CONFIRM enabled, continuing automatically."
        return
    fi

    printf "Pre-check finished. Continue with backup? (y/n): "
    read ans
    case "$ans" in
        y|Y) log "Continuing backup..." ;;
        *)   log "Backup aborted."; exit 0 ;;
    esac
}

########################################
# BBR Backup (tile)
########################################
run_bbr_backup_tile() {
    tile="$1"

    TILE_DIR="${SUMMARY_DIR}/bbr/${tile}"
    mkdir -p "${TILE_DIR}"

    log "Starting BBR backup for: ${tile}"

    CMD="bbr deployment --target ${BOSH_TARGET} \
        --username ${BOSH_USER} \
        --private-key-path ${PRIVATE_KEY_PATH} \
        --deployment ${tile} \
        backup --artifact-path ${TILE_DIR}"

    # The POSIX-safe debug flag
    if [ "${DEBUG}" = "true" ]; then
        CMD="${CMD} --debug"
    fi

    sh -c "${CMD}" > "${TILE_DIR}/bbr-backup.log" 2>&1

    if [ $? -eq 0 ]; then
        log "BBR backup completed for ${tile}"
    else
        log "BBR backup FAILED for ${tile}"
    fi
}

########################################
# Parallel BBR backup
########################################
run_bbr_backup_parallel() {
    log "Running BBR backups in parallel (max ${MAX_PARALLEL})..."

    count=0
    for tile in ${TAS_TILES}; do
        run_bbr_backup_tile "${tile}" &
        count=$((count+1))

        if [ $((count % MAX_PARALLEL)) -eq 0 ]; then
            wait
        fi
    done

    wait
    log "All BBR backups completed."
}

########################################
# Export OM configuration
########################################
export_om_config() {
    OM_DIR="${SUMMARY_DIR}/om"
    mkdir -p "${OM_DIR}"

    log "Exporting OM staged-config..."
    om --target "${OM_TARGET}" \
       --username "${OM_USERNAME}" \
       --password "${OM_PASSWORD}" \
       staged-config --include-credentials \
       > "${OM_DIR}/om-staged-config.json" \
       2> "${OM_DIR}/om-staged-config.log"

    log "Exporting installation settings..."
    om --target "${OM_TARGET}" \
       --username "${OM_USERNAME}" \
       --password "${OM_PASSWORD}" \
       export-installation \
       > "${OM_DIR}/om-installation-settings.json" \
       2> "${OM_DIR}/om-installation-settings.log"
}

completion() {
    log "Backup completed. Artifacts stored in ${SUMMARY_DIR}"
    log "Pre-check summary available at ${SUMMARY_FILE}"
}

########################################
# Script Execution
########################################
create_dirs
rotate_old_backups
detect_tiles
pre_check
prompt_continue
run_bbr_backup_parallel
export_om_config
completion

