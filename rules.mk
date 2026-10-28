EXTRACTOR_DIR ?= extractor

# tx-archive lives in the gnolang/gno monorepo under contribs/tx-archive.
# contribs/*/go.mod files use `replace github.com/gnolang/gno => ../..` so
# `go run <path>@version` does not work remotely — we must build from a
# local checkout.
#
# GNO_REF must match the build the target chain runs, so an active chain's
# Makefile pins the gno release tag its nodes run (e.g. `v1.5.1`), bumped with
# every node upgrade; archived dirs keep the `chain/*` ref they were exported
# with. A `chain/*` name is ambiguous: most exist both as a release branch and
# as a tag, and `git clone --branch` picks the branch.
#
# tx-archive amino-decodes the node's block results with the gno types from
# this ref, and amino rejects unknown JSON fields: on `master` the fetch dies
# with `unknown JSON field "errors" for type vm.TypeCheckError` against
# gnoland1, whose build carries that field (dropped from master in #5893).
GNO_REF      ?= master
# Ref is part of the path so bumping GNO_REF re-clones instead of silently
# reusing a checkout of the previous ref.
GNO_REPO     ?= $(HOME)/.cache/tx-exports/gno-$(subst /,-,$(GNO_REF))
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
# `|` delimits the sed expressions: make before 4.3 reads `#` inside
# $(shell ...) as the start of a comment
BACKUP_REMOTE = $(shell echo $(REMOTE) | tr -d '"' | sed -e 's|^http://|ws://|' -e 's|^https://|wss://|')/websocket
else
WS_FLAG       =
BACKUP_REMOTE = $(REMOTE)
endif

# fetch refuses to run unless the RPC serves the chain this directory archives:
# a hostname can answer for another chain (e.g. a new testnet's RPC hostname
# served by its predecessor's nodes before launch), and the backup would record
# that chain's blocks under this directory.
.PHONY: check-chain-id
check-chain-id:
	@if [ -z "$(CHAIN_ID)" ]; then \
		echo "$(SHORTNAME): CHAIN_ID is not set" >&2; exit 1; \
	fi
	@actual=$$(curl -fsS $(REMOTE)/status | jq -r '.result.node_info.network'); \
	if [ "$$actual" != "$(CHAIN_ID)" ]; then \
		echo "$(SHORTNAME): RPC serves chain '$$actual', expected '$(CHAIN_ID)'" >&2; exit 1; \
	fi

# --batch 100: the RPC nodes enforce a 10s WebSocket write deadline (tm2
# defaultWSWriteWait). Assembling a batch response for tx-archive's default
# 1000 blocks takes longer than that in tx-dense ranges, and the server
# drops the connection mid-fetch.
.PHONY: fetch
fetch: check-chain-id tx-archive-ensure
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

# Without a numeric height from the RPC, `seq` would fail inside the backticks
# and the loop would fetch nothing yet exit 0.
.PHONY: fetch-all
fetch-all:
	@case "$(LATEST_BLOCK_HEIGHT)" in \
		'' | *[!0-9]*) echo "$(SHORTNAME): no block height from the RPC (got '$(LATEST_BLOCK_HEIGHT)')" >&2; exit 1 ;; \
	esac
	@for i in `seq $(FROM_BLOCK) $(MAX_INTERVAL) $(LATEST_BLOCK_HEIGHT)`; do \
		$(MAKE) -C . fetch FROM_BLOCK="$$i" || exit 1; \
	done

# The files stats reads: every backup is one tx per line. A chain dir whose
# backup_*.jsonl also matches non-tx files (staging's balances) narrows it.
BACKUP_FILES ?= backup_*.jsonl

# Deployed packages are the /vm.m_addpkg messages (a /vm.m_run carries a
# package too); their keys are lowercase (`path`) except in test2 and test3,
# exported before gno#2019's snake_case JSON tags (`Path`).
#
# bash with pipefail, so a failing jq or cat fails the run instead of writing
# an empty section; and a BACKUP_FILES that matches nothing stops it before
# README.md is touched.
.PHONY: stats
stats: SHELL := /usr/bin/env bash -o pipefail
stats:
	$(if $(wildcard $(BACKUP_FILES)),,$(error $(SHORTNAME): no file matches BACKUP_FILES=$(BACKUP_FILES)))
	echo "# $(REMOTE)" > README.md
	echo >> README.md

	echo "## TXs" >> README.md
	echo '```' >> README.md
	cat $(BACKUP_FILES) | wc -l >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## addpkgs" >> README.md
	echo '```' >> README.md
	cat $(BACKUP_FILES) | jq '.tx.msg[] | select(.["@type"]=="/vm.m_addpkg") | .package | (.path // .Path) | select( . != null )' | sort | uniq -c | sort --stable -nr >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top realm calls" >> README.md
	echo '```' >> README.md
	cat $(BACKUP_FILES) | jq '.tx.msg[].pkg_path | select( . != null )' | sort | uniq -c | sort --stable -nr >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top faucet requesters" >> README.md
	echo '```' >> README.md
	cat $(BACKUP_FILES) | jq -r '.tx.msg[] | select(.["@type"]=="/bank.MsgSend") | select(.["from_address"]=="g127jydsh6cms3lrtdenydxsckh23a8d6emqcvfa") | .to_address + " " + .amount' | sed 's/ugnot$$//' | awk 'NR == 1 {next} {a[$$1] += $$2} {b[$$1] += 1} END {for (i in a) {if (a[i] >= 500000000){printf "%-15s\t%s\t%s\n", i, b[i], a[i]}}}' | sort -rnk2 >> README.md
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
