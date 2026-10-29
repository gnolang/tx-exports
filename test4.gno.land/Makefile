EXTRACTOR_DIR = extractor
REMOTE = "https://rpc.test4.gnodevx.network"
SHORTNAME = test4

# test4's backups are {tx, blockNum} lines, older than {tx, metadata}
EXTRACTOR_FLAGS = -legacy-mode

# at an average of 3 secs per block (from gnoscan), test4 produces 28_800 blocks per day
# 100k allows us to be able to catch up
MAX_INTERVAL = 100000

FROM_BLOCK = $(shell cat metadata.json | jq -r '.latest_block_height')
LATEST_BLOCK_HEIGHT = $(shell curl -s $(REMOTE)/status | jq -r '.result.sync_info.latest_block_height')
TO_BLOCK = $(LATEST_BLOCK_HEIGHT)

ifeq ($(shell echo "$(TO_BLOCK) - $(FROM_BLOCK) > $(MAX_INTERVAL)" | bc ), 1)
	TO_BLOCK = $(shell echo "$(FROM_BLOCK) + $(MAX_INTERVAL)" | bc)
endif

-include ../rules.mk
