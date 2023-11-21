REMOTE = test2.gno.land:36657
SHORTNAME = test2
LOOP_DURATION = 50000

MAX_INTERVAL = 10000

FROM_BLOCK = $(shell cat metadata.json | jq -r '.latest_block_height')
TO_BLOCK = $(shell curl -s $(REMOTE)/status | jq -r '.result.sync_info.latest_block_height')

ifeq ($(shell echo "$(TO_BLOCK) - $(FROM_BLOCK) > $(MAX_INTERVAL)" | bc ), 1)
	TO_BLOCK = $(shell echo "$(FROM_BLOCK) + $(MAX_INTERVAL)" | bc)
endif

-include ../rules.mk
