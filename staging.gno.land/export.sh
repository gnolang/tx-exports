#!/bin/bash
set -euo pipefail
set -x

TMP_DIR="temp-gno"
GENESIS="genesis.json"
WGET_OUTPUT="wget-genesis.json"
BACKUP_NAME_TXS="backup_staging_txs.jsonl"
BACKUP_NAME_BALANCES="backup_staging_balances.jsonl"
LATEST_BACKUP_FILE_TXS="latest_backup_staging_txs"
BACKUP_CHUNK_PREFIX="../backup_staging_txs"
CHUNK_SIZE=1000

# chunk_file splits a file into chunks of CHUNK_SIZE lines
chunk_file() {
    local input_file="$1"   # input file name
    local output_prefix="$2" # output file prefix (template path)
    local chunk_size="$3"    # number of lines per chunk
    local total_lines
    total_lines=$(wc -l < "$input_file" | tr -d '[:space:]')
    local start_line=1

    while [ "$start_line" -le "$total_lines" ]; do
        local end_line=$(( start_line + chunk_size - 1 ))
        if [ "$end_line" -gt "$total_lines" ]; then
            end_line="$total_lines"
        fi

        local output_file="${output_prefix}_${start_line}-${end_line}.jsonl"
        sed -n "${start_line},${end_line}p" "$input_file" > "$output_file"
        start_line=$(( end_line + 1 ))
    done
}

# merge_backup_files merges all transaction chunks into one file
merge_backup_files() {
    cat $(ls "${BACKUP_CHUNK_PREFIX}"_* 2>/dev/null | sort -V) > "$LATEST_BACKUP_FILE_TXS"
}

# backup_files_exist checks if there are any existing backup chunk files
backup_files_exist() {
    ls "${BACKUP_CHUNK_PREFIX}"_* > /dev/null 2>&1
}

# update_backup_chunks takes in a diff file and updates the backup chunks
update_backup_chunks() {
    local diff_file="$1"
    local chunk_size="$CHUNK_SIZE"

    # Find the last backup file.
    local last_chunk
    last_chunk=$(ls "${BACKUP_CHUNK_PREFIX}"_* 2>/dev/null | sort -V | tail -n 1)

    # Compute how many lines are already in the last chunk (trim any whitespace)
    local last_chunk_lines
    last_chunk_lines=$(wc -l < "$last_chunk" | tr -d '[:space:]')
    local remaining_lines=$(( chunk_size - last_chunk_lines ))

    # Extract the "last transaction number" from the filename.
    # Filenames are of the form: <prefix>_<start>-<end>.jsonl
    local last_tx_number
    last_tx_number=$(basename "$last_chunk" | sed -E 's/.*-([0-9]+)\.jsonl/\1/')
    last_tx_number=$((10#$last_tx_number))  # convert to a number

    # Count the number of lines in the diff file
    local diff_total
    diff_total=$(wc -l < "$diff_file" | tr -d '[:space:]')

    if [ "$remaining_lines" -eq 0 ]; then
        # Last chunk is full. Create new chunks directly from the diff file.
        local new_tx_start=$(( last_tx_number + 1 ))
        while true; do
            local remaining_diff
            remaining_diff=$(wc -l < "$diff_file" | tr -d '[:space:]')
            if [ "$remaining_diff" -le 0 ]; then
                break
            fi

            if [ "$remaining_diff" -le "$chunk_size" ]; then
                local new_tx_end=$(( new_tx_start + remaining_diff - 1 ))
                local new_chunk_file="${BACKUP_CHUNK_PREFIX}_${new_tx_start}-${new_tx_end}.jsonl"

                mv "$diff_file" "$new_chunk_file"

                break
            else
                head -n "$chunk_size" "$diff_file" > "new_chunk.tmp"
                local new_tx_end=$(( new_tx_start + chunk_size - 1 ))
                local new_chunk_file="${BACKUP_CHUNK_PREFIX}_${new_tx_start}-${new_tx_end}.jsonl"

                mv "new_chunk.tmp" "$new_chunk_file"

                new_tx_start=$(( new_tx_end + 1 ))
                tail -n +$(( chunk_size + 1 )) "$diff_file" > "${diff_file}.tmp"
                mv "${diff_file}.tmp" "$diff_file"
            fi
        done

    elif [ "$remaining_lines" -ge "$diff_total" ]; then
        # There is enough room in the last chunk: append all diff lines
        cat "$diff_file" >> "$last_chunk"
        local new_end_tx
        new_end_tx=$(printf "%d" $(( last_tx_number + diff_total )))

        local new_last_chunk
        new_last_chunk=$(echo "$last_chunk" | sed -E "s/(_[0-9]+-)[0-9]+(\.jsonl)/\1${new_end_tx}\2/")

        mv "$last_chunk" "$new_last_chunk"
    else
        # Append as many lines as possible into the last chunk
        head -n "$remaining_lines" "$diff_file" >> "$last_chunk"
        local new_end_tx
        new_end_tx=$(printf "%d" $(( last_tx_number + remaining_lines )))

        local new_last_chunk
        new_last_chunk=$(echo "$last_chunk" | sed -E "s/(_[0-9]+-)[0-9]+(\.jsonl)/\1${new_end_tx}\2/")

        mv "$last_chunk" "$new_last_chunk"

        # Remove the lines that were appended from the diff file
        tail -n +$(( remaining_lines + 1 )) "$diff_file" > "${diff_file}.tmp"
        mv "${diff_file}.tmp" "$diff_file"

        local new_tx_start=$(( new_end_tx + 1 ))
        while true; do
            local remaining_diff
            remaining_diff=$(wc -l < "$diff_file" | tr -d '[:space:]')
            if [ "$remaining_diff" -le 0 ]; then
                break
            fi

            if [ "$remaining_diff" -le "$chunk_size" ]; then
                local new_tx_end=$(( new_tx_start + remaining_diff - 1 ))
                local new_chunk_file="${BACKUP_CHUNK_PREFIX}_${new_tx_start}-${new_tx_end}.jsonl"

                mv "$diff_file" "$new_chunk_file"

                break
            else
                head -n "$chunk_size" "$diff_file" > "new_chunk.tmp"
                local new_tx_end=$(( new_tx_start + chunk_size - 1 ))
                local new_chunk_file="${BACKUP_CHUNK_PREFIX}_${new_tx_start}-${new_tx_end}.jsonl"

                mv "new_chunk.tmp" "$new_chunk_file"

                new_tx_start=$(( new_tx_end + 1 ))
                tail -n +$(( chunk_size + 1 )) "$diff_file" > "${diff_file}.tmp"

                mv "${diff_file}.tmp" "$diff_file"
            fi
        done
    fi
}

# --- MAIN LOGIC --- #

# Count existing backed-up transactions (by line count, NOT content comparison).
# The Portal Loop uses --lazy init which regenerates keys each restart,
# so creator addresses change every export. We cannot compare content —
# we can only use line counts to determine new transactions.
# NOTE: BACKUP_CHUNK_PREFIX is "../backup_staging_txs" (relative to temp-gno/).
# Before cd-ing into temp-gno/, we must use the direct path.
EXISTING_TX_COUNT=0
if ls backup_staging_txs_*.jsonl > /dev/null 2>&1; then
    EXISTING_TX_COUNT=$(cat $(ls backup_staging_txs_*.jsonl | sort -V) | wc -l | tr -d '[:space:]')
fi

# Create the local temporary directory.
rm -rf "$TMP_DIR"
mkdir "$TMP_DIR"
cd "$TMP_DIR" || exit 1

# Download the latest genesis.json from the Portal Loop RPC
wget -O "$WGET_OUTPUT" https://rpc.staging.gno.land/genesis

# Extract the genesis portion from the wget response
jq ".result.genesis" "$WGET_OUTPUT" > "$GENESIS"

# Clone and build the gnogenesis tool (needed to export txs and balances)
git clone https://github.com/gnolang/gno.git
cd gno/contribs/gnogenesis || exit 1
make build
cd ../../..  # Return to the root (staging.gno.land) directory

# Export genesis transactions and balances
./gno/contribs/gnogenesis/build/gnogenesis txs export -genesis-path "$GENESIS" "$BACKUP_NAME_TXS"
./gno/contribs/gnogenesis/build/gnogenesis balances export -genesis-path "$GENESIS" "$BACKUP_NAME_BALANCES"

# Strip the ephemeral genesis deployer account from the balances export.
# On each Portal Loop restart, gnoland --lazy generates a fresh validator key
# and sets its balance to len(genesisTxs)*2_100_000 ugnot so it can pay for
# replaying all genesis transactions. That address changes every restart and
# is an implementation detail — not a real user account. We identify it as the
# creator of the first MsgAddPackage in the genesis (examples are always loaded
# first, all signed by the deployer/txSender key).
DEPLOYER_ADDR=$(jq -r '[.app_state.txs[].tx.msg[] | select(.["@type"] == "/vm.m_addpkg")] | first | .creator' "$GENESIS")
if [ -n "$DEPLOYER_ADDR" ] && [ "$DEPLOYER_ADDR" != "null" ]; then
    grep -v "^${DEPLOYER_ADDR}=" "$BACKUP_NAME_BALANCES" > "${BACKUP_NAME_BALANCES}.tmp"
    mv "${BACKUP_NAME_BALANCES}.tmp" "$BACKUP_NAME_BALANCES"
fi

# Clean up the downloaded genesis files.
rm "$GENESIS" "$WGET_OUTPUT"

# Always update balances (small file, may change).
cp "$BACKUP_NAME_BALANCES" "../$BACKUP_NAME_BALANCES"

NEW_TX_COUNT=$(wc -l < "$BACKUP_NAME_TXS" | tr -d '[:space:]')

if [ "$EXISTING_TX_COUNT" -eq 0 ]; then
    # No existing backups — create initial chunks from the full export.
    echo "No backup sheets found. Creating initial backup sheets."
    chunk_file "$BACKUP_NAME_TXS" "$BACKUP_CHUNK_PREFIX" "$CHUNK_SIZE"
elif [ "$NEW_TX_COUNT" -gt "$EXISTING_TX_COUNT" ]; then
    # Extract only the NEW transactions (lines beyond what we already have).
    DIFF_TXS="diff.jsonl"
    tail -n +$(( EXISTING_TX_COUNT + 1 )) "$BACKUP_NAME_TXS" > "$DIFF_TXS"

    DIFF_COUNT=$(wc -l < "$DIFF_TXS" | tr -d '[:space:]')
    echo "Found $DIFF_COUNT new transactions. Updating backup files."
    update_backup_chunks "$DIFF_TXS"
else
    echo "No new transactions found ($NEW_TX_COUNT total, $EXISTING_TX_COUNT already backed up). Exiting."
fi

# Move back to the parent directory and clean up
cd .. || exit 1
rm -rf "$TMP_DIR"
