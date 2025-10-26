#!/bin/bash

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
if [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAMES" ] || \
   [ -z "$S3_BUCKET_NAME" ] || [ -z "$S3_ENDPOINT" ] || \
   [ -z "$S3_ACCESS_KEY_ID" ] || [ -z "$S3_SECRET_ACCESS_KEY" ]; then
    echo "Error: Missing required environment variables in .env file"
    exit 1
fi

# Export AWS credentials for AWS CLI
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"

# Set MySQL password via environment variable
export MYSQL_PWD="$DB_PASS"

# ----------------------
# Settings
# ----------------------
DATE=$(date +%F)

# Backup directory
BACKUP_DIR="$SCRIPT_DIR/backups"

# Convert DB_NAMES from comma-separated string to array
IFS=',' read -r -a DB_NAMES <<< "$DB_NAMES"

# --- Config for tables to ignore ---
declare -A DB_IGNORE_TABLES

# Parse IGNORE_TABLES format: "db1.table1,db1.table2,db2.table3"
if [ -n "$IGNORE_TABLES" ]; then
    IFS=',' read -r -a ENTRIES <<< "$IGNORE_TABLES"
    for ENTRY in "${ENTRIES[@]}"; do
        IFS='.' read -r DB_NAME TABLE_NAME <<< "$ENTRY"
        if [ -n "$DB_NAME" ] && [ -n "$TABLE_NAME" ]; then
            if [ -n "${DB_IGNORE_TABLES[$DB_NAME]}" ]; then
                DB_IGNORE_TABLES["$DB_NAME"]+=" $TABLE_NAME"
            else
                DB_IGNORE_TABLES["$DB_NAME"]="$TABLE_NAME"
            fi
        fi
    done
fi

mkdir -p "$BACKUP_DIR"

echo ""
echo "Starting database backup..."

# ----------------------
# Backup Databases
# ----------------------
for DB_NAME in "${DB_NAMES[@]}"; do
    echo "Backing up ${DB_NAME}..."

    IGNORE_PARAMS=""
    # Check if there are tables to ignore and build params
    if [[ -v "DB_IGNORE_TABLES[$DB_NAME]" ]]; then
        echo "  Ignoring tables: ${DB_IGNORE_TABLES[$DB_NAME]}"
        for TBL in ${DB_IGNORE_TABLES[$DB_NAME]}; do
            IGNORE_PARAMS+=" --ignore-table=${DB_NAME}.${TBL}"
        done
    fi

    # Dump structure, then data (with ignores if any)
    (
        mysqldump --no-data -u $DB_USER $DB_NAME
        mysqldump --single-transaction --quick --no-tablespaces --disable-keys --set-gtid-purged=OFF \
            -u $DB_USER $DB_NAME $IGNORE_PARAMS --no-create-info
    ) | gzip > "$BACKUP_DIR/${DB_NAME}_${DATE}.sql.gz"

    echo "  ✓ ${DB_NAME} backed up successfully"
done

# ----------------------
# Upload to S3
# ----------------------
aws s3 sync $BACKUP_DIR "s3://$S3_BUCKET_NAME" \
    --endpoint-url $S3_ENDPOINT \
    --exact-timestamps

# ----------------------
# Cleanup old backups
# ----------------------
for DB_NAME in "${DB_NAMES[@]}"; do
    echo "Cleaning up old backups for ${DB_NAME}..."

    # --- Local Cleanup ---
    ls -t "$BACKUP_DIR/${DB_NAME}_"*.sql.gz | tail -n +$((KEEP_COUNT + 1)) | xargs -I {} rm -f {}

    # --- S3 Cleanup ---
    OBJECTS=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET_NAME" --prefix "${DB_NAME}_" --endpoint-url "$S3_ENDPOINT" --query "sort_by(Contents, &LastModified)[].[Key]" --output text)
    OBJECT_COUNT=$(echo "$OBJECTS" | grep -c .)

    if [ "$OBJECT_COUNT" -gt "$KEEP_COUNT" ]; then
        DELETE_COUNT=$((OBJECT_COUNT - KEEP_COUNT))
        OBJECTS_TO_DELETE=$(echo "$OBJECTS" | head -n $DELETE_COUNT | awk '{print "Key="$1}' | tr '\n' ' ')

        if [ -n "$OBJECTS_TO_DELETE" ]; then
            aws s3api delete-objects --bucket "$S3_BUCKET_NAME" --delete "Objects=[{${OBJECTS_TO_DELETE%?}}]" --endpoint-url "$S3_ENDPOINT"
        fi
    fi
done

# ----------------------
# Heartbeat
# ----------------------
if [ $? -eq 0 ]; then
    echo "✓ Backup completed successfully at $(date '+%Y-%m-%d %H:%M:%S')"

    if [ -n "$HEARTBEAT_URL" ]; then
        curl -fsS -m 10 --retry 3 -o /dev/null "$HEARTBEAT_URL"
    fi
else
    echo "✗ Backup failed at $(date '+%Y-%m-%d %H:%M:%S')"
fi
