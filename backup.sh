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
if [ -z "$DB_USERNAME" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_DATABASES" ] || \
   [ -z "$AWS_BUCKET" ] || [ -z "$AWS_ENDPOINT" ] || \
   [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Error: Missing required environment variables in .env file"
    exit 1
fi

# Set MySQL password via environment variable
export MYSQL_PWD="$DB_PASSWORD"

# ----------------------
# Settings
# ----------------------
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# Backup directory
BACKUP_DIR="$SCRIPT_DIR/backups"

# Convert DB_DATABASES from comma-separated string to array
IFS=',' read -r -a DATABASES <<< "$DB_DATABASES"

# --- Config for tables to ignore ---
declare -A IGNORE_TABLES

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

echo ""
echo "Starting database backup..."

# ----------------------
# Backup Databases
# ----------------------
for DATABASE in "${DATABASES[@]}"; do
    echo "Backing up ${DATABASE}..."

    IGNORE_PARAMS=""
    # Check if there are tables to ignore and build params
    if [[ -v "IGNORE_TABLES[$DATABASE]" ]]; then
        echo "  Ignoring tables: ${IGNORE_TABLES[$DATABASE]}"
        for TBL in ${IGNORE_TABLES[$DATABASE]}; do
            IGNORE_PARAMS+=" --ignore-table=${DATABASE}.${TBL}"
        done
    fi

    # Dump structure, then data (with ignores if any)
    (
        mysqldump --no-data -u $DB_USERNAME $DATABASE
        mysqldump --single-transaction --quick --no-tablespaces --disable-keys --set-gtid-purged=OFF \
            -u $DB_USERNAME $DATABASE $IGNORE_PARAMS --no-create-info
    ) | gzip > "$BACKUP_DIR/${DATABASE}_${DATE}.sql.gz"

    echo "  ✓ ${DATABASE} backed up successfully"
done

# ----------------------
# Upload to S3
# ----------------------
aws s3 sync $BACKUP_DIR "s3://$AWS_BUCKET" \
    --endpoint-url $AWS_ENDPOINT \
    --exact-timestamps

# ----------------------
# Cleanup old backups
# ----------------------
for DATABASE in "${DATABASES[@]}"; do
    echo "Cleaning up old backups for ${DATABASE}..."

    # --- Local Cleanup ---
    ls -t "$BACKUP_DIR/${DATABASE}_"*.sql.gz | tail -n +$((KEEP_COUNT + 1)) | xargs -I {} rm -f {}

    # --- S3 Cleanup ---
    OBJECTS=$(aws s3api list-objects-v2 --bucket "$AWS_BUCKET" --prefix "${DATABASE}_" --endpoint-url "$AWS_ENDPOINT" --query "sort_by(Contents, &LastModified)[].[Key]" --output text)
    OBJECT_COUNT=$(echo "$OBJECTS" | grep -c .)

    if [ "$OBJECT_COUNT" -gt "$KEEP_COUNT" ]; then
        DELETE_COUNT=$((OBJECT_COUNT - KEEP_COUNT))
        OBJECTS_TO_DELETE=$(echo "$OBJECTS" | head -n $DELETE_COUNT)

        if [ -n "$OBJECTS_TO_DELETE" ]; then
            echo "$OBJECTS_TO_DELETE" | while read -r OBJECT; do
                if [ -n "$OBJECT" ]; then
                    aws s3 rm "s3://$AWS_BUCKET/$OBJECT" --endpoint-url "$AWS_ENDPOINT" > /dev/null 2>&1
                    echo "  ✓ Deleted old backup: $OBJECT"
                fi
            done
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
