#!/bin/bash

#---------------------------------------
# TAS + OM Backup Script
#---------------------------------------

# Load environment variables
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/tas_backup.env"

DATE=$(date +%Y%m%d_%H%M%S)
MAX_PARALLEL=3

SUMMARY_FILE="${BACKUP_DIR}/${DATE}/precheck-summary.log"

#-------------------
# Functions
#-------------------
log(){
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

create_dirs(){
    mkdir -p "${BACKUP_DIR}/${DATE}/bbr"
    mkdir -p "${BACKUP_DIR}/${DATE}/om"
    mkdir -p "$(dirname "${SUMMARY_FILE}")"
    log "Created backup directories under ${BACKUP_DIR}/${DATE}"
}

rotate_old_backups(){
    log "Rotating backup older than ${ROTATE_DAYS} days..."
    find "${BACKUP_DIR}" -maxdepth 1 -type d -mtime +${ROTATE_DAYS} -exec rm -rf {} \;
}

detect_tiles(){
    log "Detecting TAS tiles from BOSH deployments..."
    # Auto-detect TAS tiles (all starting with p-)
    TAS_TILES=($(bosh -e "${BOSH_TARGET}" ssh "${BOSH_USER}" --private-key="${PRIVATE_KEY_PATH}" -d | awk '{print $1}' | grep -E '^p-'))

    # Detect CF Deployment (any deployment starting with "cf")
    CF_DEPLOYMENT=($(bosh -e "${BOSH_TARGET}" ssh "${BOSH_USER}" --private-key="${PRIVATE_KEY_PATH}" -d | awk '{print $1}' | grep -E '^cf'))

    # Merge TAS tiles + CF Deployments
    TAS_TILES+=("${CF_DEPLOYMENTS[@]}")

    # Remove duplicates
    TAS_TILES=($(echo "${TAS_TILES[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    if [ ${#TAS_TILES[@]} -eq 0 ]; then
        log "no TAS/cf tiles detected. Exiting"
        exit 1
    else
        log "Detected tiles: ${TAS_TILES[@]}"
        echo "Detected tiles: ${TAS_TILES[@]}" >> "${SUMMARY_FILE}"
    fi
}

pre_check() {
    echo "==== Pre-check summary =====" > "${SUMMARY_FILE}"
    log "Starting pre-checks..."

    # 1. BOSH Connectivity
    log "Checking BOSH director connectivity..."
    bosh -e "${BOSH_TARGET}" env > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "BOSH director reachable."
        echo "BOSH director connectivity: OK" >> "${SUMMARY_FILE}"
    else
        log "BOSH director unreachable!"
        echo "BOSH director connectivity: FAILED" >> "${SUMMARY_FILE}"
        exit 1
    fi

    # 2. Disk space check
    REQUIRED_SPACE_MB=5000
    AVAILABLE_SPACE_MB=$(df -Pm "${BACKUP_DIR}" | tail -1 | awk '{print $4}' )
    if [ "${AVAILABLE_SPACE_MB}" -ge "${REQUIRED_SPACE_MB}" ]; then
        log "Sufficient disk space: ${AVAILABLE_SPACE_MB}MB"
        echo "Disk space available: ${AVAILABLE_SPACE_MB}MB (Required: ${REQUIRED_SPACE_MB}MB) - OK" >> "${SUMMARY_FILE}"
    else
        log "Insufficient disk space: ${AVAILABLE_SPACE_MB}MB"
        echo "Disk space available: ${AVAILABLE_SPACE_MB}MB (Required: ${REQUIRED_SPACE_MB}MB) - FAILED" >> "${SUMMARY_FILE}"
        exit 1
    fi

    # 3. BBR pre-backup check
    log "Running BBR pre-backup-check ..."
    for tile in "${TAS_TILES[@]}"; do
        TILE_LOG="${BACKUP_DIR}/${DATE}/bbr/${tile}/precheck.log"
        mkdir -p "${BACKUP_DIR}/${DATE}/bbr/${tile}"
        bbr deployment --target "${BOSH_TARGET}" --username "${BOSH_USER}" --private-key-path "${PRIVATE_KEY_PATH}" --deployment "${tile}" pre-backup-check > "${TILE_LOG}" 2>&1

        if [ $? -eq 0 ]; then
            log "BBR pre-backup-check passed for ${tile}."
            echo "${tile}: BBR pre-backup-check: OK" >> "${SUMMARY_FILE}"
        else 
            log "BBR pre-backup-check FAILED for ${tile}. Check ${TILE_LOG}"
            echo "${tile}: BBR pre-backup-check: FAILED (See ${TILE_LOG})" >> "${SUMMARY_FILE}"
        fi
    done

    log "Pre-check completed. Summary written to ${SUMMARY_FILE}"
}

prompt_continue() {
    if [ "$AUTO_CONFIRM" = true ]; then
        log "AUTO_CONFIRM set. Continuing backup automatically."
        return
    read -p "Pre-check finished. Do you want to continue with backup? (y/n): " choice
    case "$choice" in
     y|Y ) log "User confirmed to continue with backup." ;;
     n|N ) log "Backup aborted by user."; exit 0 ;;
     * ) log "Invalid choice. Backup aborted."; exit 1;;
    esac
}

run_bbr_backup_tile(){
    local tile=$1
    TILE_DIR="${BACKUP_DIR}/${DATE}/bbr/${tile}"
    mkdir -p "${TILE_DIR}"

    log "Starting BBR backup for tile: ${tile}"
    CMD="bbr deployment --target ${BOSH_TARGET} --username ${BOSH_USER} --private-key-path ${PRIVATE_KEY_PATH} --deployment ${tile} backup --artifact-path ${TILE_DIR}"

    if [ "$DEBUG" = true ]; then
        CMD="${CMD} --debug"
    fi

    ${CMD} > "${TILE_DIR}/bbr-backup.log" 2>&1

    if [ $? -eq 0 ]; then
        log "BBR backup for ${tile} completed successfully. Logs at ${TILE_DIR}/bbr-backup.log"
    else
        log "BBR backup for ${tile} FAILED. Check ${TILE_DIR}/bbr-backup.log"
}

run_bbr_backup_parallel(){
    log "Running BBR backups in parallel (max ${MAX_PARALLEL} concurrent jobs)..."
    count=0

    for tile in "${TAS_TILES[@]}"; do
        run_bbr_backup_tile "$tile" & ((count++))
        if (( count % MAX_PARALLEL == 0 )); then wait; fi
    done
    wait
    log "All BBR backup completed."
}

export_om_config() {
    OM_DIR="${BACKUP_DIR}/${DATE}/om"
    mkdir -p "${OM_DIR}"

    log "Exporting OM staged-config..."
    om --target "${OM_TARGET}" --username "${OM_USERNAME}" --password "${OM_PASSWORD}" staged-config --include-credentials > "${OM_DIR}/om-staged-config.json" 2> "${OMD_DIR}/om-staged-config.log"

    if [ $? -eq 0 ]; then
        log "OM staged-config exported successfully."
    else
        log "OM staged-config export FAILED. Check ${OM_DIR}/om-staged-config.log"
    
    log "Exporting OM installation settings..."
    om --target "${OM_TARGET} --username "${OM_USERNAME}" --password "${OM_PASSWORD} export-installation > "${OM_DIR}/om-installation-settings.json" 2> "${OM_DIR}/om-installation-settings.log"

    if [ $? -eq 0 ]; then
        log "OM installation settings exported successfully."
    else
        log "OM installation settings export FAILED. Check ${OM_DIR}/om-installation-settings.log"
}

completion(){
    log "Backup process completed. Artifacts store in ${BACKUP_DIR}/${DATE}"
    log "Pre-check summary is available at ${SUMMARY_FILE}"
}

#-------------------
# Script Execution
#-------------------
create_dirs
rotate_old_backups
detect_tiles
pre_check
prompt_continue
run_bbr_backup_parallel
export_om_config
completion