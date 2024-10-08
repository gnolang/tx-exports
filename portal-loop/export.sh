#!/bin/bash

set -xe

# Define the constants
TMP_DIR=temp-gno # Temporary directory for the working data
GENESIS=genesis.json
WGET_OUTPUT=wget-genesis.json
BACKUP_PREFIX=backup_
BACKUP_NAME=backup_portal_loop.jsonl
# Latest backup is commited in the repo
LATEST_BACKUP_FILE=../"$BACKUP_NAME"

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
./gno/gno.land/build/gnoland genesis txs export -genesis-path $GENESIS "$BACKUP_NAME"

# Clean up the downloaded genesis.json and the wget response
rm $GENESIS $WGET_OUTPUT

# Check if there is an existing backup
if [[ ! -f "$LATEST_BACKUP_FILE" ]]; then
  # Save the initial backup
  echo "Saving initial backup to $BACKUP_NAME"

  # Make the backup file official
  cp "$BACKUP_NAME" "$LATEST_BACKUP_FILE"
else # Backup file exists!
  LATEST_BACKUP_SORTED=latest_backup_sort.jsonl
  DIFF_TXS=diff.jsonl

  # There is an existing backup already, check it
  echo "Backup file already present in the repository"

  # Sort the latest backup file
  sort "$LATEST_BACKUP_FILE" > "$LATEST_BACKUP_SORTED"
  
  # Sort the latest genesis tx sheet
  sort "$BACKUP_NAME" > temp_"$BACKUP_NAME"

  # Use comm to find lines only in file2 (additions) and write to output file
  comm -13 ./"$LATEST_BACKUP_SORTED" temp_"$BACKUP_NAME" > "$DIFF_TXS"

  # Notify if differences were found
  if [[ -z $(grep '[^[:space:]]' "$DIFF_TXS") ]]; then
    echo "No differences found. Exiting with no further activities."
  else
    echo "Differences found. Replacing backup file"
    # Make the backup file official
    cp "$BACKUP_NAME" "$LATEST_BACKUP_FILE"
    echo "Stored a new backup file"
  fi
fi

cd .. || exit 1

# Clean up the temporary directory
rm -rf $TMP_DIR
