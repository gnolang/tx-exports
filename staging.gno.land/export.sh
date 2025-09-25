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

# Wipe the existing backups.
# The reason for this is because the PL uses --lazy init
# which generates fresh keys for genesis txs, causing a discrepancy
# in already backed up files (there is always a diff, because of sig diffs).
# When technology evolves and we stop using a trash implementation of the Portal Loop,
# this should be dropped
rm -f backup_staging_txs_*.jsonl

# Create the local temporary directory.
rm -rf "$TMP_DIR"
mkdir "$TMP_DIR"
cd "$TMP_DIR" || exit 1

# Download the latest genesis.json from the Portal Loop RPC
wget -O "$WGET_OUTPUT" https://rpc.gno.land/genesis

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

# Clean up the downloaded genesis files.
rm "$GENESIS" "$WGET_OUTPUT"

# If there are no backup chunk files yet, split the current export into chunks.
if ! backup_files_exist; then
    echo "No backup sheets found. Creating initial backup sheets"
    rm -f "${BACKUP_CHUNK_PREFIX}"_*
    chunk_file "$BACKUP_NAME_TXS" "$BACKUP_CHUNK_PREFIX" "$CHUNK_SIZE"
    # Also copy the balances file one level up.
    cp "$BACKUP_NAME_BALANCES" "../$BACKUP_NAME_BALANCES"
else
    echo "Backup sheets already exist. Merging and updating with new transactions"
    merge_backup_files

    DIFF_TXS="diff.jsonl"

    # Find transactions present in the new export that aren't in the backups
    comm -13 "${LATEST_BACKUP_FILE_TXS}" "${BACKUP_NAME_TXS}" > "$DIFF_TXS"

    if [[ ! -s "$DIFF_TXS" ]]; then
        echo "No differences found. Exiting."
    else
        echo "Differences found. Updating backup files."
        update_backup_chunks "$DIFF_TXS"
    fi
fi

# Move back to the parent directory and clean up
cd .. || exit 1
rm -rf "$TMP_DIR"
