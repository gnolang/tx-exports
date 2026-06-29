REMOTE = "https://rpc.test13.testnets.gno.land"
SHORTNAME = test13

# Fetch over WebSocket: the HTTP RPC endpoint WAF-blocks (403) high-volume batch
# fetches, which strands the daily backup. A single WS connection avoids it.
USE_WS = 1

# at an average of 3 secs per block, test13 produces ~28_800 blocks per day
# 100k allows us to catch up if the exporter falls behind
MAX_INTERVAL = 10000

FROM_BLOCK = $(shell cat metadata.json | jq -r '.latest_block_height + 1')
LATEST_BLOCK_HEIGHT = $(shell curl -s $(REMOTE)/status | jq -r '.result.sync_info.latest_block_height')
TO_BLOCK = $(LATEST_BLOCK_HEIGHT)

ifeq ($(shell echo "$(TO_BLOCK) - $(FROM_BLOCK) >= $(MAX_INTERVAL)" | bc ), 1)
	TO_BLOCK = $(shell echo "$(FROM_BLOCK) + $(MAX_INTERVAL) - 1" | bc)
endif

-include ../rules.mk
