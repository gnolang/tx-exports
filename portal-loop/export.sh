#!/bin/bash

set -xe

# Define the constants
TMP_DIR=temp-gno # Temporary directory for the working data
GENESIS=genesis.json
WGET_OUTPUT=wget-genesis.json
BACKUP_NAME_TXS=backup_portal_loop_txs.jsonl
BACKUP_NAME_BALANCES=backup_portal_loop_balances.jsonl
# Latest backup is committed in the repo
LATEST_BACKUP_FILE_TXS=latest_backup_portal_loop_txs
# template for chunks of stored backups
BACKUP_CHUNK_TEMPLATE=../backup_portal_loop_txs

# Function to copy backup files
copyBackupFiles () {
  MAX_INTERVAL=1000
  FROM_LINE=1
  TO_LINE=$MAX_INTERVAL
  TOT_LINES=$(wc -l < "$BACKUP_NAME_TXS" | bc)

  # clean directory
  rm -f "$BACKUP_CHUNK_TEMPLATE"*
  while [ $(($TO_LINE % $MAX_INTERVAL)) -eq 0 ]
  do
    # gather files in interval
    sed -n "${FROM_LINE},${TO_LINE}p" "$BACKUP_NAME_TXS" > "$BACKUP_CHUNK_TEMPLATE"_$FROM_LINE-$TO_LINE.jsonl
    # increment intervals
    FROM_LINE=$(( $FROM_LINE + $MAX_INTERVAL ))
    TO_LINE=$(( $TO_LINE + $MAX_INTERVAL ))
    # correct in case of last file interval
    TO_LINE=$(( $TO_LINE < $TOT_LINES ? $TO_LINE : $TOT_LINES ))
  done
  # copy last chunk
  sed -n "${FROM_LINE},${TO_LINE}p" "$BACKUP_NAME_TXS" > "$BACKUP_CHUNK_TEMPLATE"_$FROM_LINE-$TO_LINE.jsonl
  # backup balances
  cp "$BACKUP_NAME_BALANCES" ../"$BACKUP_NAME_BALANCES"
}

# Create the temporary working dir
rm -rf $TMP_DIR && mkdir $TMP_DIR
cd $TMP_DIR || exit 1

# Grab the latest genesis.json
wget -O $WGET_OUTPUT https://rpc.gno.land/genesis

# Extract the wget genesis response
jq ".result.genesis" $WGET_OUTPUT > $GENESIS

# Install the gnoland binary
git clone https://github.com/gnolang/gno.git
cd gno/contribs/gnogenesis || exit 1
make build
cd ../../.. # move back to the portal-loop directory

# Extract the genesis transactions
./gno/contribs/gnogenesis/build/gnogenesis txs export -genesis-path $GENESIS "$BACKUP_NAME_TXS"
# Extract the genesis balances
./gno/contribs/gnogenesis/build/gnogenesis balances export -genesis-path $GENESIS "$BACKUP_NAME_BALANCES"

# Clean up the downloaded genesis.json and the wget response
rm $GENESIS $WGET_OUTPUT

# Function to check if backup files exist
backup_files_exist() {
  ls "$BACKUP_CHUNK_TEMPLATE"* 1> /dev/null 2>&1
}

# Function to merge backup files into a single file
merge_backup_files() {
  cat $(ls "$BACKUP_CHUNK_TEMPLATE"* | sort) > "$LATEST_BACKUP_FILE_TXS"
}

# Function to sort a file
sort_file() {
  local input_file=$1
  local output_file=$2
  sort "$input_file" > "$output_file"
}

# Function to calculate remaining lines in the last chunk
calculate_remaining_lines() {
  local last_chunk=$1
  local last_line=$(wc -l < "$last_chunk" | tr -d ' ')
  echo $((1000 - last_line))
}

# Function to get the last transaction number from a chunk file name
get_last_tx_number() {
  local chunk_file=$1
  echo $(basename "$chunk_file" | sed -E 's/.*-([0-9]+)\.jsonl/\1/')
}

# Function to update or create a backup chunk
update_backup_chunks() {
  local diff_file=$1
  local last_chunk=$(ls "$BACKUP_CHUNK_TEMPLATE"* | sort | tail -n 1)
  local remaining_lines=$(calculate_remaining_lines "$last_chunk")

  if [[ $remaining_lines -eq 0 ]]; then
    # Last chunk is full, create a new chunk
    local new_chunk_start=$(( $(get_last_tx_number "$last_chunk") + 1 ))
    local new_chunk_end=$((new_chunk_start + $(wc -l < "$diff_file") - 1))
    cp "$diff_file" "$BACKUP_CHUNK_TEMPLATE"_"$new_chunk_start"-"$new_chunk_end".jsonl
  else
    local diff_lines=$(wc -l < "$diff_file")

    if [[ $diff_lines -le $remaining_lines ]]; then
      # Append all diffs to the last chunk
      cat "$diff_file" >> "$last_chunk"
      local new_end_tx=$(( $(get_last_tx_number "$last_chunk") + $diff_lines ))
      mv "$last_chunk" "$(dirname "$last_chunk")/$(basename "$last_chunk" | sed -E 's/-[0-9]+\.jsonl/-'"$new_end_tx"'.jsonl/')"
    else
      # Fill the remaining lines in the last chunk and create a new chunk
      head -n $remaining_lines "$diff_file" >> "$last_chunk"
      local new_end_tx=$(( $(get_last_tx_number "$last_chunk") + $remaining_lines ))
      mv "$last_chunk" "$(dirname "$last_chunk")/$(basename "$last_chunk" | sed -E 's/-[0-9]+\.jsonl/-'"$new_end_tx"'.jsonl/')"

      local new_chunk_start=$((new_end_tx + 1))
      local new_chunk_end=$((new_chunk_start + $diff_lines - $remaining_lines - 1))
      tail -n +$((remaining_lines + 1)) "$diff_file" > "$BACKUP_CHUNK_TEMPLATE"_"$new_chunk_start"-"$new_chunk_end".jsonl
    fi
  fi
}

# Main script logic
if ! backup_files_exist; then
  echo "Saving initial backup to $BACKUP_CHUNK_TEMPLATE*"
  copyBackupFiles
else
  echo "Backup files already present. Merging and comparing with incoming file."
  merge_backup_files

  DIFF_TXS="diff.jsonl"

  sort_file "$LATEST_BACKUP_FILE_TXS" "temp_${LATEST_BACKUP_FILE_TXS}"
  sort_file "$BACKUP_NAME_TXS" "temp_${BACKUP_NAME_TXS}"

  # Find differences
  comm -13 "temp_${LATEST_BACKUP_FILE_TXS}" "temp_${BACKUP_NAME_TXS}" > "$DIFF_TXS"

  if [[ -z $(grep '[^[:space:]]' "$DIFF_TXS") ]]; then
    echo "No differences found. Exiting."
  else
    echo "Differences found. Updating backup files."
    update_backup_chunks "$DIFF_TXS"
  fi
fi

cd .. || exit 1

# Clean up the temporary directory
rm -rf $TMP_DIR
