REMOTE = "https://rpc.topaz.testnets.gno.land"
SHORTNAME = topaz

# Fetch over WebSocket: testnets.gno.land HTTP RPC endpoints WAF-block (403)
# high-volume batch fetches, which strands the backup. A single WS connection
# avoids it.
USE_WS = 1

# at an average of 3 secs per block, the chain produces ~28_800 blocks per day;
# 10k blocks per run across six runs a day leaves headroom to catch up if the
# exporter falls behind
MAX_INTERVAL = 10000

FROM_BLOCK = $(shell cat metadata.json | jq -r '.latest_block_height + 1')
LATEST_BLOCK_HEIGHT = $(shell curl -s $(REMOTE)/status | jq -r '.result.sync_info.latest_block_height')
TO_BLOCK = $(LATEST_BLOCK_HEIGHT)

ifeq ($(shell echo "$(TO_BLOCK) - $(FROM_BLOCK) >= $(MAX_INTERVAL)" | bc ), 1)
	TO_BLOCK = $(shell echo "$(FROM_BLOCK) + $(MAX_INTERVAL) - 1" | bc)
endif

-include ../rules.mk
