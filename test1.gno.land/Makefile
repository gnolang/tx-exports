REMOTE = test1.gno.land:36657
SHORTNAME = test1
LOOP_DURATION = 50000


FROM_BLOCK = $(shell cat metadata.json | jq -r '.latest_block_height')
LATEST_BLOCK_HEIGHT = $(shell curl -s $(REMOTE)/status | jq -r '.result.sync_info.latest_block_height')
TO_BLOCK = $(LATEST_BLOCK_HEIGHT)

ifeq ($(shell echo "$(TO_BLOCK) - $(FROM_BLOCK) > $(MAX_INTERVAL)" | bc ), 1)
	TO_BLOCK = $(shell echo "$(FROM_BLOCK) + $(MAX_INTERVAL)" | bc)
endif

-include ../rules.mk
