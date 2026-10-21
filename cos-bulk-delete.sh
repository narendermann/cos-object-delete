#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# ---------------------------------------------------------------------------
# IBM Cloud Object Storage paginated bulk deletion
#
# Requirements:
#   - IBM Cloud CLI
#   - cloud-object-storage CLI plug-in
#   - jq
#   - IAM access capable of listing and deleting objects
#
# Usage:
#   ./cos-bulk-delete.sh \
#       --bucket bucket-conair-pvsibmi-uss \
#       --region us-south \
#       --execute
#
# Dry run:
#   ./cos-bulk-delete.sh \
#       --bucket bucket-conair-pvsibmi-uss \
#       --region us-south
#
# Optional:
#   --prefix "some/prefix/"
#   --batch-size 1000
#   --max-retries 8
#   --state-dir ./cos-delete-state
#   --resume
# ---------------------------------------------------------------------------

BUCKET=""
REGION=""
PREFIX=""
BATCH_SIZE=1000
MAX_RETRIES=8
INITIAL_RETRY_DELAY=2
STATE_DIR="./cos-delete-state"
EXECUTE=false
RESUME=false

usage() {
    cat <<'EOF'
Usage:
  cos-bulk-delete.sh --bucket BUCKET --region REGION [options]

Required:
  --bucket NAME          IBM Cloud COS bucket name
  --region REGION        Bucket region, for example us-south

Options:
  --prefix PREFIX        Delete only keys beginning with this prefix
  --batch-size NUMBER    Objects per delete request, 1-1000; default 1000
  --max-retries NUMBER   Maximum retries per list/delete request; default 8
  --state-dir DIRECTORY  Logs and checkpoint directory
  --resume               Resume using the saved pagination token
  --execute              Perform deletion; otherwise dry-run only
  --help                 Display this help

Examples:
  # Dry run
  ./cos-bulk-delete.sh \
      --bucket bucket-conair-pvsibmi-uss \
      --region us-south

  # Delete all current objects
  ./cos-bulk-delete.sh \
      --bucket bucket-conair-pvsibmi-uss \
      --region us-south \
      --execute

  # Resume an interrupted run
  ./cos-bulk-delete.sh \
      --bucket bucket-conair-pvsibmi-uss \
      --region us-south \
      --state-dir ./cos-delete-state \
      --resume \
      --execute
EOF
}

log() {
    local level="$1"
    shift

    printf '%s [%s] %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "$level" \
        "$*" |
        tee -a "$LOG_FILE" >&2
}

die() {
    log "ERROR" "$*"
    exit 1
}

retry_command() {
    local description="$1"
    shift

    local attempt=1
    local delay="$INITIAL_RETRY_DELAY"
    local rc

    while true; do
        set +e
        "$@"
        rc=$?
        set -e

        if (( rc == 0 )); then
            return 0
        fi

        if (( attempt >= MAX_RETRIES )); then
            log "ERROR" \
                "$description failed after $attempt attempts; exit code=$rc"
            return "$rc"
        fi

        log "WARN" \
            "$description failed on attempt $attempt/$MAX_RETRIES; retrying after ${delay}s"

        sleep "$delay"

        attempt=$((attempt + 1))

        # Exponential backoff, capped at 60 seconds.
        delay=$((delay * 2))
        if (( delay > 60 )); then
            delay=60
        fi
    done
}

while (( $# > 0 )); do
    case "$1" in
        --bucket)
            [[ $# -ge 2 ]] || {
                echo "Missing value after --bucket" >&2
                exit 2
            }
            BUCKET="$2"
            shift 2
            ;;
        --region)
            [[ $# -ge 2 ]] || {
                echo "Missing value after --region" >&2
                exit 2
            }
            REGION="$2"
            shift 2
            ;;
        --prefix)
            [[ $# -ge 2 ]] || {
                echo "Missing value after --prefix" >&2
                exit 2
            }
            PREFIX="$2"
            shift 2
            ;;
        --batch-size)
            [[ $# -ge 2 ]] || {
                echo "Missing value after --batch-size" >&2
                exit 2
            }
            BATCH_SIZE="$2"
            shift 2
            ;;
        --max-retries)
            [[ $# -ge 2 ]] || {
                echo "Missing value after --max-retries" >&2
                exit 2
            }
            MAX_RETRIES="$2"
            shift 2
            ;;
        --state-dir)
            [[ $# -ge 2 ]] || {
                echo "Missing value after --state-dir" >&2
                exit 2
            }
            STATE_DIR="$2"
            shift 2
            ;;
        --resume)
            RESUME=true
            shift
            ;;
        --execute)
            EXECUTE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$BUCKET" ]] || {
    echo "ERROR: --bucket is required" >&2
    exit 2
}

[[ -n "$REGION" ]] || {
    echo "ERROR: --region is required" >&2
    exit 2
}

[[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] ||
    {
        echo "ERROR: --batch-size must be numeric" >&2
        exit 2
    }

(( BATCH_SIZE >= 1 && BATCH_SIZE <= 1000 )) ||
    {
        echo "ERROR: --batch-size must be between 1 and 1000" >&2
        exit 2
    }

[[ "$MAX_RETRIES" =~ ^[0-9]+$ ]] ||
    {
        echo "ERROR: --max-retries must be numeric" >&2
        exit 2
    }

(( MAX_RETRIES >= 1 )) ||
    {
        echo "ERROR: --max-retries must be at least 1" >&2
        exit 2
    }

for command_name in ibmcloud jq mktemp; do
    command -v "$command_name" >/dev/null 2>&1 ||
        {
            echo "ERROR: Required command not found: $command_name" >&2
            exit 1
        }
done

ibmcloud plugin show cloud-object-storage >/dev/null 2>&1 ||
    {
        echo "ERROR: IBM Cloud Object Storage CLI plug-in is missing." >&2
        echo "Install it with:" >&2
        echo "  ibmcloud plugin install cloud-object-storage" >&2
        exit 1
    }

mkdir -p "$STATE_DIR"

LOG_FILE="$STATE_DIR/delete.log"
TOKEN_FILE="$STATE_DIR/next-token"
TOTAL_FILE="$STATE_DIR/deleted-count"
FAILED_KEYS_FILE="$STATE_DIR/failed-keys.jsonl"
COMPLETED_FILE="$STATE_DIR/completed"

touch "$LOG_FILE"
touch "$FAILED_KEYS_FILE"

if [[ -f "$COMPLETED_FILE" && "$RESUME" == true ]]; then
    die "The state directory is marked completed; use a new state directory"
fi

if [[ "$RESUME" != true ]]; then
    rm -f "$TOKEN_FILE" "$TOTAL_FILE" "$COMPLETED_FILE"
    : > "$FAILED_KEYS_FILE"
fi

TOTAL_DELETED=0

if [[ -f "$TOTAL_FILE" ]]; then
    SAVED_TOTAL="$(cat "$TOTAL_FILE")"
    if [[ "$SAVED_TOTAL" =~ ^[0-9]+$ ]]; then
        TOTAL_DELETED="$SAVED_TOTAL"
    fi
fi

NEXT_TOKEN=""

if [[ "$RESUME" == true && -s "$TOKEN_FILE" ]]; then
    NEXT_TOKEN="$(cat "$TOKEN_FILE")"
    log "INFO" "Resuming from saved pagination token"
elif [[ "$RESUME" == true ]]; then
    log "WARN" "Resume requested, but no pagination token was found"
fi

WORK_DIR="$(mktemp -d "$STATE_DIR/work.XXXXXX")"

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT
trap 'log "ERROR" "Stopped unexpectedly at line $LINENO"' ERR
trap 'log "WARN" "Interrupted; checkpoint retained in $STATE_DIR"; exit 130' INT TERM

LIST_JSON="$WORK_DIR/list.json"
LIST_STDERR="$WORK_DIR/list.stderr"
DELETE_JSON="$WORK_DIR/delete.json"
DELETE_STDERR="$WORK_DIR/delete.stderr"
PAYLOAD_JSON="$WORK_DIR/delete-payload.json"
FAILED_PAYLOAD_JSON="$WORK_DIR/failed-delete-payload.json"

log "INFO" "Bucket: $BUCKET"
log "INFO" "Region: $REGION"
log "INFO" "Prefix: ${PREFIX:-<all objects>}"
log "INFO" "Batch size: $BATCH_SIZE"
log "INFO" "Maximum retries: $MAX_RETRIES"
log "INFO" "State directory: $STATE_DIR"
log "INFO" "Execute mode: $EXECUTE"

log "INFO" "Checking bucket accessibility"

retry_command \
    "Bucket accessibility check" \
    ibmcloud cos bucket-head \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --output json \
        >/dev/null

PAGE_NUMBER=0

while true; do
    PAGE_NUMBER=$((PAGE_NUMBER + 1))

    LIST_COMMAND=(
        ibmcloud cos list-objects-v2
        --bucket "$BUCKET"
        --region "$REGION"
        --page-size "$BATCH_SIZE"
        --max-items "$BATCH_SIZE"
        --output json
    )

    if [[ -n "$PREFIX" ]]; then
        LIST_COMMAND+=(--prefix "$PREFIX")
    fi

    if [[ -n "$NEXT_TOKEN" ]]; then
        LIST_COMMAND+=(--starting-token "$NEXT_TOKEN")
    fi

    : > "$LIST_JSON"
    : > "$LIST_STDERR"

    log "INFO" "Listing page $PAGE_NUMBER"

    if ! retry_command \
        "List page $PAGE_NUMBER" \
        "${LIST_COMMAND[@]}" \
        >"$LIST_JSON" \
        2>"$LIST_STDERR"; then

        cat "$LIST_STDERR" >> "$LOG_FILE"
        die "Unable to list page $PAGE_NUMBER"
    fi

    if ! jq empty "$LIST_JSON" >/dev/null 2>&1; then
        log "ERROR" "List response was not valid JSON"
        cat "$LIST_STDERR" >> "$LOG_FILE"
        exit 1
    fi

    OBJECT_COUNT="$(
        jq '
            [
                (
                    .Contents
                    // .contents
                    // []
                )[]
                | select((.Key // .key) != null)
            ]
            | length
        ' "$LIST_JSON"
    )"

    # IBM CLI pagination normally exposes NextToken. The additional names
    # make the script tolerant of SDK-style field naming.
    LIST_NEXT_TOKEN="$(
        jq -r '
            .NextToken
            // .nextToken
            // .next_token
            // .NextContinuationToken
            // .nextContinuationToken
            // .next_continuation_token
            // empty
        ' "$LIST_JSON"
    )"

    if (( OBJECT_COUNT == 0 )); then
        log "INFO" "No objects returned on page $PAGE_NUMBER"

        if [[ -z "$LIST_NEXT_TOKEN" ]]; then
            break
        fi

        NEXT_TOKEN="$LIST_NEXT_TOKEN"
        printf '%s' "$NEXT_TOKEN" > "$TOKEN_FILE"
        continue
    fi

    jq '
        {
            Objects: [
                (
                    .Contents
                    // .contents
                    // []
                )[]
                | {
                    Key: (.Key // .key)
                }
                | select(.Key != null)
            ],
            Quiet: true
        }
    ' "$LIST_JSON" > "$PAYLOAD_JSON"

    PAYLOAD_COUNT="$(jq '.Objects | length' "$PAYLOAD_JSON")"

    if (( PAYLOAD_COUNT != OBJECT_COUNT )); then
        die "Payload count $PAYLOAD_COUNT differs from list count $OBJECT_COUNT"
    fi

    log "INFO" \
        "Page $PAGE_NUMBER contains $PAYLOAD_COUNT objects"

    if [[ "$EXECUTE" != true ]]; then
        log "INFO" \
            "DRY RUN: would delete $PAYLOAD_COUNT objects from page $PAGE_NUMBER"

        jq -r '.Objects[].Key' "$PAYLOAD_JSON" |
            sed -n '1,10p' |
            while IFS= read -r key; do
                log "DRYRUN" "Sample key: $key"
            done
    else
        : > "$DELETE_JSON"
        : > "$DELETE_STDERR"

        log "INFO" \
            "Deleting $PAYLOAD_COUNT objects from page $PAGE_NUMBER"

        if ! retry_command \
            "Delete page $PAGE_NUMBER" \
            ibmcloud cos objects-delete \
                --bucket "$BUCKET" \
                --delete "file://$PAYLOAD_JSON" \
                --region "$REGION" \
                --output json \
                >"$DELETE_JSON" \
                2>"$DELETE_STDERR"; then

            cat "$DELETE_STDERR" >> "$LOG_FILE"
            die "Bulk deletion failed for page $PAGE_NUMBER"
        fi

        if ! jq empty "$DELETE_JSON" >/dev/null 2>&1; then
            log "ERROR" "Delete response was not valid JSON"
            cat "$DELETE_STDERR" >> "$LOG_FILE"
            exit 1
        fi

        ERROR_COUNT="$(
            jq '
                (
                    .Errors
                    // .errors
                    // []
                )
                | length
            ' "$DELETE_JSON"
        )"

        if (( ERROR_COUNT > 0 )); then
            log "WARN" \
                "$ERROR_COUNT objects failed within page $PAGE_NUMBER"

            jq -c '
                (
                    .Errors
                    // .errors
                    // []
                )[]
            ' "$DELETE_JSON" >> "$FAILED_KEYS_FILE"

            # Retry only the keys reported as failed.
            jq '
                {
                    Objects: [
                        (
                            .Errors
                            // .errors
                            // []
                        )[]
                        | {
                            Key: (.Key // .key)
                        }
                        | select(.Key != null)
                    ],
                    Quiet: true
                }
            ' "$DELETE_JSON" > "$FAILED_PAYLOAD_JSON"

            RETRY_OBJECT_COUNT="$(
                jq '.Objects | length' "$FAILED_PAYLOAD_JSON"
            )"

            if (( RETRY_OBJECT_COUNT > 0 )); then
                : > "$DELETE_JSON"
                : > "$DELETE_STDERR"

                if ! retry_command \
                    "Retry failed objects on page $PAGE_NUMBER" \
                    ibmcloud cos objects-delete \
                        --bucket "$BUCKET" \
                        --delete "file://$FAILED_PAYLOAD_JSON" \
                        --region "$REGION" \
                        --output json \
                        >"$DELETE_JSON" \
                        2>"$DELETE_STDERR"; then

                    cat "$DELETE_STDERR" >> "$LOG_FILE"
                    die "Failed-object retry exhausted on page $PAGE_NUMBER"
                fi

                REMAINING_ERRORS="$(
                    jq '
                        (
                            .Errors
                            // .errors
                            // []
                        )
                        | length
                    ' "$DELETE_JSON"
                )"

                if (( REMAINING_ERRORS > 0 )); then
                    jq -c '
                        (
                            .Errors
                            // .errors
                            // []
                        )[]
                    ' "$DELETE_JSON" >> "$FAILED_KEYS_FILE"

                    die "$REMAINING_ERRORS objects still failed after retries on page $PAGE_NUMBER"
                fi
            fi
        fi

        TOTAL_DELETED=$((TOTAL_DELETED + PAYLOAD_COUNT))
        printf '%s\n' "$TOTAL_DELETED" > "$TOTAL_FILE"

        log "INFO" \
            "Page $PAGE_NUMBER completed; cumulative deleted=$TOTAL_DELETED"
    fi

    # Save the token only after the page has been processed successfully.
    NEXT_TOKEN="$LIST_NEXT_TOKEN"

    if [[ -n "$NEXT_TOKEN" ]]; then
        printf '%s' "$NEXT_TOKEN" > "$TOKEN_FILE"
    else
        rm -f "$TOKEN_FILE"
        break
    fi
done

if [[ "$EXECUTE" == true ]]; then
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$COMPLETED_FILE"

    log "INFO" "Bulk deletion pass completed"
    log "INFO" "Successful delete count: $TOTAL_DELETED"
    log "INFO" "Failed-key records: $FAILED_KEYS_FILE"
else
    log "INFO" "Dry run completed; no objects were deleted"
fi