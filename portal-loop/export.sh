#!/bin/bash

set -xe

# Define the constants
TMP_DIR=temp-gno # Temporary directory for the working data
GENESIS=genesis.json
WGET_OUTPUT=wget-genesis.json
BACKUP_NAME_TXS=backup_portal_loop_txs.jsonl
BACKUP_NAME_BALANCES=backup_portal_loop_balances.jsonl
# Latest backup is commited in the repo
LATEST_BACKUP_FILE_TXS=latest_backup_portal_loop_txs 
# template for chunks of stored backups
BACKUP_CHUNK_TEMPLATE=../backup_portal_loop_txs

# Make the generated backup files the reference ones stored into the repository
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

# Check if there is an existing backup
if ! ls "$BACKUP_CHUNK_TEMPLATE"* 1> /dev/null 2>&1; then
  # Save the initial backup
  echo "Saving initial backup to $BACKUP_CHUNK_TEMPLATE*"

  # Make the backup files official
  copyBackupFiles
else # Backup files exist!
  # merge backup files into a unique file
  cat $(ls "$BACKUP_CHUNK_TEMPLATE"* | sort) > $LATEST_BACKUP_FILE_TXS
  DIFF_TXS=diff.jsonl

  # There is an existing backup already, check it
  echo "Backup files already present in the repository. Merging and comparing with incoming file"

  # Sort the latest backup file
  sort "$LATEST_BACKUP_FILE_TXS" > temp_"$LATEST_BACKUP_FILE_TXS"
  
  # Sort the latest genesis tx sheet
  sort "$BACKUP_NAME_TXS" > temp_"$BACKUP_NAME_TXS"

  # Compare existing and incoming txs backup files both sorted
  # Use comm to find lines only in the incoming txs backup and write to an output file
  comm -13 temp_"$LATEST_BACKUP_FILE_TXS" temp_"$BACKUP_NAME_TXS" > "$DIFF_TXS"

  # Notify if differences were found
  if [[ -z $(grep '[^[:space:]]' "$DIFF_TXS") ]]; then
    echo "No differences found. Exiting with no further activities."
  else
    echo "Differences found. Replacing backup files"
    # Make the backup files official
    copyBackupFiles
    echo "Stored new backup files for balances and txs"
  fi
fi

cd .. || exit 1

# Clean up the temporary directory
rm -rf $TMP_DIR
