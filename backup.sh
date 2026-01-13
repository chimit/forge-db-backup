#!/bin/bash

# Exit on error and pipe failures
set -eo pipefail

# ----------------------
# Load environment variables
# ----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found in $SCRIPT_DIR"
    exit 1
fi

# Load .env file
set -a
source "$ENV_FILE"
set +a

# Validate required variables
if [ -z "$DB_USERNAME" ] || [ -z "$DB_DATABASES" ] || \
   [ -z "$AWS_BUCKET" ] || [ -z "$AWS_ENDPOINT" ] || \
   [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Error: Missing required environment variables in .env file"
    exit 1
fi

# Set MySQL password via environment variable (if provided)
if [ -n "$DB_PASSWORD" ]; then
    export MYSQL_PWD="$DB_PASSWORD"
fi

# ----------------------
# Settings
# ----------------------
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# Backup directory
BACKUP_DIR="$SCRIPT_DIR/backups"

# Convert DB_DATABASES from comma-separated string to array
IFS=',' read -r -a DATABASES <<< "$DB_DATABASES"

# --- Config for tables to ignore ---
declare -A IGNORE_TABLES 2>/dev/null || true

# Parse DB_IGNORE_TABLES format: "db1.table1,db1.table2,db2.table3"
if [ -n "$DB_IGNORE_TABLES" ]; then
    IFS=',' read -r -a ENTRIES <<< "$DB_IGNORE_TABLES"

    for ENTRY in "${ENTRIES[@]}"; do
        IFS='.' read -r DATABASE TABLE <<< "$ENTRY"
        if [ -n "$DATABASE" ] && [ -n "$TABLE" ]; then
            if [ -n "${IGNORE_TABLES[$DATABASE]}" ]; then
                IGNORE_TABLES["$DATABASE"]+=" $TABLE"
            else
                IGNORE_TABLES["$DATABASE"]="$TABLE"
            fi
        fi
    done
fi

mkdir -p "$BACKUP_DIR"

START_TIME=$(date +%s)

echo "Starting database backup..."

# ----------------------
# Process each database completely
# ----------------------
for DATABASE in "${DATABASES[@]}"; do
    echo ""
    echo "Processing ${DATABASE}..."

    # --- 1. Backup ---
    IGNORE_PARAMS=""
    # Check if there are tables to ignore and build params
    if [ -n "${IGNORE_TABLES[$DATABASE]}" ]; then
        echo "  Ignoring tables: $(echo "${IGNORE_TABLES[$DATABASE]}" | sed 's/ /, /g')"

        for TBL in ${IGNORE_TABLES[$DATABASE]}; do
            IGNORE_PARAMS+=" --ignore-table=${DATABASE}.${TBL}"
        done
    fi

    BACKUP_FILE="$BACKUP_DIR/${DATABASE}_${DATE}.sql.gz"

    # Dump structure, then data (with ignores if any)
    (
        mysqldump --no-data -u $DB_USERNAME $DATABASE
        mysqldump --single-transaction --quick --no-tablespaces --disable-keys --set-gtid-purged=OFF \
            -u $DB_USERNAME $DATABASE $IGNORE_PARAMS --no-create-info
    ) | gzip > "$BACKUP_FILE"

    echo "  ✓ Backup created successfully: $(basename "$BACKUP_FILE")"

    # --- 2. Cleanup old local backups ---
    ls -t "$BACKUP_DIR/${DATABASE}_"*.sql.gz 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) | while read -r FILE; do
        rm -f "$FILE"
        echo "  ✓ Deleted old local backup: $(basename "$FILE")"
    done || true

    # --- 3. Upload new backup to S3 ---
    if ! aws s3 cp "$BACKUP_FILE" "s3://$AWS_BUCKET/$(basename "$BACKUP_FILE")" \
        --endpoint-url $AWS_ENDPOINT > /dev/null 2>&1; then
        echo "  ✗ Error: Failed to upload to S3"
        exit 1
    fi

    echo "  ✓ Uploaded to S3 ($(du -k "$BACKUP_FILE" | awk '{printf "%.2f MB", $1/1024}'))"

    # --- 4. Cleanup old S3 backups ---
    aws s3api list-objects-v2 --bucket "$AWS_BUCKET" --prefix "${DATABASE}_" --endpoint-url "$AWS_ENDPOINT" \
        --query "sort_by(Contents, &LastModified)[:-$KEEP_COUNT].[Key]" --output text 2>/dev/null | \
    while read -r OBJECT; do
        if [ -n "$OBJECT" ]; then
            aws s3 rm "s3://$AWS_BUCKET/$OBJECT" --endpoint-url "$AWS_ENDPOINT" > /dev/null 2>&1
            echo "  ✓ Deleted old S3 backup: $OBJECT"
        fi
    done || true
done

ELAPSED=$(($(date +%s) - START_TIME))

echo ""
echo "✓ All backups completed successfully on $(date '+%a, %b %-d, %Y at %H:%M:%S') ($((ELAPSED / 60))m $((ELAPSED % 60))s)"

if [ -n "$HEARTBEAT_URL" ]; then
    curl -fsS -m 10 --retry 3 -o /dev/null "$HEARTBEAT_URL" || true
fi
