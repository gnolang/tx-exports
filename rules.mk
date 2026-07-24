EXTRACTOR_DIR ?= extractor

# tx-archive lives in the gnolang/gno monorepo under contribs/tx-archive.
# contribs/*/go.mod files use `replace github.com/gnolang/gno => ../..` so
# `go run <path>@version` does not work remotely — we must build from a
# local checkout.
GNO_REPO     ?= $(HOME)/.cache/tx-exports/gno
GNO_REF      ?= master
TXARCHIVE    ?= $(GNO_REPO)/contribs/tx-archive

.PHONY: all
all:
	@echo 'use make fetch or make fetch-all to download blocks'
	$(MAKE) join stats extractor

$(TXARCHIVE)/cmd/main.go:
	@mkdir -p $(dir $(GNO_REPO))
	@if [ ! -d $(GNO_REPO) ]; then \
		git clone --depth=1 --branch $(GNO_REF) https://github.com/gnolang/gno.git $(GNO_REPO); \
	else \
		git -C $(GNO_REPO) fetch --depth=1 origin $(GNO_REF) && \
		git -C $(GNO_REPO) checkout FETCH_HEAD; \
	fi

.PHONY: tx-archive-ensure
tx-archive-ensure: $(TXARCHIVE)/cmd/main.go ## clone/update the gno repo so tx-archive is runnable

# Backup transport selection.
# Set USE_WS=1 in a chain Makefile to fetch over a WebSocket connection
# (wss://<host>/websocket) instead of HTTP(S). A single long-lived WS connection
# avoids the per-request rate limiting / WAF blocks that some RPC endpoints apply
# to high-volume HTTP batch fetches, at the cost of slower fetches (tx results are
# not batched over WS). REMOTE stays HTTP(S) so the latest-block curl still works.
ifeq ($(USE_WS),1)
WS_FLAG       = -ws
BACKUP_REMOTE = $(shell echo $(REMOTE) | tr -d '"' | sed -e 's#^http://#ws://#' -e 's#^https://#wss://#')/websocket
else
WS_FLAG       =
BACKUP_REMOTE = $(REMOTE)
endif

# --batch 100: the RPC nodes enforce a 10s WebSocket write deadline (tm2
# defaultWSWriteWait). Assembling a batch response for tx-archive's default
# 1000 blocks takes longer than that in tx-dense ranges, and the server
# drops the connection mid-fetch.
.PHONY: fetch
fetch: tx-archive-ensure
	@echo "Backup from: $(FROM_BLOCK) to $(TO_BLOCK)"
	cd $(TXARCHIVE) && go run ./cmd backup -verbose $(WS_FLAG) \
		--batch 100 \
		--remote $(BACKUP_REMOTE) \
		--from-block $(FROM_BLOCK) \
		--to-block   $(TO_BLOCK) \
		--output-path "$(shell pwd)/backup_$(shell printf '%07d' $(FROM_BLOCK))-$(shell printf '%07d' $(TO_BLOCK)).jsonl"

    # Update metadata
	@cat metadata.json | jq -a '.latest_block_height = $(TO_BLOCK)' > /tmp/aa.json
	@mv /tmp/aa.json metadata.json

.PHONY: fetch-all
fetch-all:
	@for i in `seq $(FROM_BLOCK) $(MAX_INTERVAL) $(LATEST_BLOCK_HEIGHT)`; do \
		make -C . fetch FROM_BLOCK="$$i"; \
	done

.PHONY: stats
stats:
	echo "# $(REMOTE)" > README.md
	echo >> README.md

	echo "## TXs" >> README.md
	echo '```' >> README.md
	cat backup_*.jsonl | wc -l >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## addpkgs" >> README.md
	echo '```' >> README.md
	cat backup_*.jsonl | jq '.tx.msg[].package.Path | select( . != null )' | sort | uniq -c | sort --stable -nr >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top realm calls" >> README.md
	echo '```' >> README.md
	cat backup_*.jsonl | jq '.tx.msg[].pkg_path | select( . != null )' | sort | uniq -c | sort --stable -nr >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top faucet requesters" >> README.md
	echo '```' >> README.md
	cat backup_*.jsonl | jq -r '.tx.msg[] | select(.["@type"]=="/bank.MsgSend") | select(.["from_address"]=="g127jydsh6cms3lrtdenydxsckh23a8d6emqcvfa") | .to_address + " " + .amount' | sed 's/ugnot$$//' | awk 'NR == 1 {next} {a[$$1] += $$2} {b[$$1] += 1} END {for (i in a) {if (a[i] >= 500000000){printf "%-15s\t%s\t%s\n", i, b[i], a[i]}}}' | sort -rnk2 >> README.md
	echo '```' >> README.md
	echo >> README.md

stats-legacy:
	echo "# $(REMOTE)" > README.md
	echo >> README.md

	echo "## TXs" >> README.md
	echo '```' >> README.md
	cat backup_*.jsonl | wc -l >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## addpkgs" >> README.md
	echo '```' >> README.md
	cat backup_*.jsonl | jq '.msg[].package.Path | select( . != null )' | sort | uniq -c | sort --stable -nr >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top realm calls" >> README.md
	echo '```' >> README.md
	cat backup_*.jsonl | jq '.msg[].pkg_path | select( . != null )' | sort | uniq -c | sort --stable -nr >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top faucet requesters" >> README.md
	echo '```' >> README.md
	cat backup_*.jsonl | jq -r '.msg[] | select(.["@type"]=="/bank.MsgSend") | select(.["from_address"]=="g127jydsh6cms3lrtdenydxsckh23a8d6emqcvfa") | .to_address + " " + .amount' | sed 's/ugnot$$//' | awk 'NR == 1 {next} {a[$$1] += $$2} {b[$$1] += 1} END {for (i in a) {if (a[i] >= 500000000){printf "%-15s\t%s\t%s\n", i, b[i], a[i]}}}' | sort -rnk2 >> README.md
	echo '```' >> README.md
	echo >> README.md


# Only files with contiguous block ranges may be merged: a coverage gap
# between two files must stay visible in the file names.
.PHONY: join
join:
	@echo "Joining small backup files..."
	@prev_file=""; \
	for f in $$(ls backup_*.jsonl 2>/dev/null | sort); do \
		size=$$(stat -c%s "$$f"); \
		f_start=$$(echo "$$f" | sed 's/backup_0*\([0-9][0-9]*\)-.*/\1/'); \
		if [ -n "$$prev_file" ]; then \
			prev_size=$$(stat -c%s "$$prev_file"); \
			prev_end=$$(echo "$$prev_file" | sed 's/backup_[0-9]*-0*\([0-9][0-9]*\)\..*/\1/'); \
			if [ $$((prev_size + size)) -lt 102400 ] && [ "$$f_start" -eq $$((prev_end + 1)) ]; then \
				start=$$(echo "$$prev_file" | sed 's/backup_\([0-9]*\)-.*/\1/'); \
				end=$$(echo "$$f" | sed 's/backup_[0-9]*-\([0-9]*\)\..*/\1/'); \
				new_file="backup_$${start}-$${end}.jsonl"; \
				cat "$$prev_file" "$$f" > "$${new_file}.tmp"; \
				rm "$$prev_file" "$$f"; \
				mv "$${new_file}.tmp" "$$new_file"; \
				prev_file="$$new_file"; \
				echo "  Joined -> $$new_file ($$(stat -c%s "$$new_file") bytes)"; \
				continue; \
			fi; \
		fi; \
		prev_file="$$f"; \
	done
	@echo "Done."

.PHONY: extractor
extractor:
	go run -C "../$(EXTRACTOR_DIR)" . \
		-source-path "$(shell pwd)" \
		-output-dir "$(shell pwd)/extracted"

.PHONY: loop
loop:
	while true; do \
		( \
			set -xe; \
			make fetch; \
			make stats; \
			git add .; \
			git commit . -sm "chore: update $(SHORTNAME)"; \
			git push; \
		); \
		date; \
		sleep $(LOOP_DURATION); \
	done
