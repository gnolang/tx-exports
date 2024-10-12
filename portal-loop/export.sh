#!/bin/bash

set -xe

# Define the constants
TMP_DIR=temp-gno # Temporary directory for the working data
GENESIS=genesis.json
WGET_OUTPUT=wget-genesis.json
BACKUP_NAME_TXS=backup_portal_loop_txs.jsonl
BACKUP_NAME_BALANCES=backup_portal_loop_balances.jsonl
# Latest backup is commited in the repo
LATEST_BACKUP_FILE_TXS=../"$BACKUP_NAME_TXS"

# Make the generated backup files the reference ones stored into the repository
copyBackupFiles () {
  cp "$BACKUP_NAME_TXS" "$LATEST_BACKUP_FILE_TXS"
  cp "$BACKUP_NAME_BALANCES" ../"$BACKUP_NAME_BALANCES"
}

# Create the temporary working dir
mkdir $TMP_DIR
cd $TMP_DIR || exit 1

# Grab the latest genesis.json
wget -O $WGET_OUTPUT https://rpc.gno.land/genesis

# Extract the wget genesis response
jq ".result.genesis" $WGET_OUTPUT > $GENESIS

# Install the gnoland binary
git clone https://github.com/gnolang/gno.git
cd gno/gno.land || exit 1
make build.gnoland
cd ../.. # move back to the portal-loop directory

# Extract the genesis transactions
./gno/gno.land/build/gnoland genesis txs export -genesis-path $GENESIS "$BACKUP_NAME_TXS"
# Extract the genesis balances
./gno/gno.land/build/gnoland genesis balances export -genesis-path $GENESIS "$BACKUP_NAME_BALANCES"

# Clean up the downloaded genesis.json and the wget response
rm $GENESIS $WGET_OUTPUT

# Check if there is an existing backup
if [[ ! -f "$LATEST_BACKUP_FILE_TXS" ]]; then
  # Save the initial backup
  echo "Saving initial backup to $BACKUP_NAME_TXS"

  # Make the backup files official
  copyBackupFiles
else # Backup file exists!
  LATEST_BACKUP_SORTED=latest_backup_sort.jsonl
  DIFF_TXS=diff.jsonl

  # There is an existing backup already, check it
  echo "Backup file already present in the repository"

  # Sort the latest backup file
  sort "$LATEST_BACKUP_FILE_TXS" > "$LATEST_BACKUP_SORTED"
  
  # Sort the latest genesis tx sheet
  sort "$BACKUP_NAME_TXS" > temp_"$BACKUP_NAME_TXS"

  # Compare existing and incoming txs backup files both sorted
  # Use comm to find lines only in the incoming txs backup and write to an output file
  comm -13 ./"$LATEST_BACKUP_SORTED" temp_"$BACKUP_NAME_TXS" > "$DIFF_TXS"

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
