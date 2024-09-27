#!/bin/bash

# Define the constants
TMP_DIR=temp-gno # Temporary directory for the working data
BACKUP_NAME=backup_portal.loop.$(date +%s).jsonl
GENESIS=genesis.json
WGET_OUTPUT=wget-genesis.json
BACKUP_PREFIX=backup_

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

# Find the latest backup file based on the Unix timestamp in the filename
LATEST_BACKUP_FILE=$(ls ../"$BACKUP_PREFIX"*.jsonl 2>/dev/null | sort -t'-' -k2,2n | tail -n 1)

# Check if there is an existing backup
if [[ -z "$LATEST_BACKUP_FILE" ]]; then
  # Save the initial backup
  echo "Saving initial backup to $BACKUP_NAME"

  # Make the backup file official
  cp "$BACKUP_NAME" ../"$BACKUP_NAME"

  # Remove the temporary working directory
  cd .. || exit 1
  rm -rf $TMP_DIR
  
  exit 0
fi

# There is an existing backup already, check it
echo "Latest backup file: $LATEST_BACKUP_FILE"

LATEST_BACKUP_SORTED=latest_backup_sort.jsonl

# Sort the latest backup file
sort "$LATEST_BACKUP_FILE" > "$LATEST_BACKUP_SORTED"

# Sort the latest genesis tx sheet
sort "$BACKUP_NAME" > temp_"$BACKUP_NAME"

# Clean up the temporary backup file
rm "$BACKUP_NAME"

DIFF_TXS=diff.jsonl

# Use comm to find lines only in file2 (additions) and write to output file
comm -13 ./"$LATEST_BACKUP_SORTED" temp_"$BACKUP_NAME" > "$DIFF_TXS"

# Notify if differences were found
if [[ -z $(grep '[^[:space:]]' "$DIFF_TXS") ]]; then
  echo "No differences found."
else
  echo "Differences found."

  cp "$DIFF_TXS" ../"$BACKUP_NAME"

  echo "Differences saved to $BACKUP_NAME"
fi

cd .. || exit 1

# Clean up the temporary directory
rm -rf $TMP_DIR
