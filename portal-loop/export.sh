#!/bin/bash

# Define the constants
TMP_DIR=temp-gno
TIMESTAMP=$(date +%s)
POTENTIAL_BACKUP_NAME=backup.portal.loop.${TIMESTAMP}.jsonl
GENESIS_NAME=genesis.json

# Create the temporary working dir
mkdir $TMP_DIR
cd $TMP_DIR

output_diff=diff.jsonl
backup_name=backup.tmp.jsonl

# Grab the latest genesis.json
wget -O $GENESIS_NAME https://rpc.gno.land/genesis

# Install the gnoland binary
git clone https://github.com/gnolang/gno.git
cd gno/gno.land
make build.gnoland
cd ../..

jq ".result.genesis" $GENESIS_NAME > temp_$GENESIS_NAME
./gno/gno.land/build/gnoland genesis txs export -genesis-path temp_$GENESIS_NAME $backup_name

rm temp_$GENESIS_NAME $GENESIS_NAME

# Find the latest backup file based on the Unix timestamp in the filename
latest_backup_file=$(ls ../backup.*.jsonl 2>/dev/null | sort -t'-' -k2,2n | tail -n 1)

# Check if a file was found
if [[ -z "$latest_backup_file" ]]; then
  # just save file
  echo "Saving first time"
  cp $backup_name ../$POTENTIAL_BACKUP_NAME
  rm -rf $TMP_DIR
  
  exit 0
else
  echo "Latest backup file: $latest_backup_file"
  sort $latest_backup_file > ./latest.jsonl
  sort $backup_name > temp_$backup_name

  rm $backup_name

  # Use comm to find lines only in file2 (additions) and write to output file
  comm -13 ./latest.jsonl temp_$backup_name > $output_diff

  # Cleanup temporary sorted files
  # rm sorted_file1.jsonl sorted_file2.jsonl
fi

# Notify if differences were found
if [[ -z $(grep '[^[:space:]]' $output_diff) ]]; then
  echo "No differences found."
else
  echo "Differences found."
  cp $output_diff ../$POTENTIAL_BACKUP_NAME
fi

cd ..

rm -rf $TMP_DIR
