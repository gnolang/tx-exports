EXTRACTOR_DIR ?= extractor-0.1.1

fetch:
	@echo "Backup from: $(FROM_BLOCK) to $(TO_BLOCK)"
	go run github.com/gnolang/tx-archive/cmd@v0.5.1 backup -verbose \
		--remote $(REMOTE) \
		--from-block $(FROM_BLOCK) \
		--to-block   $(TO_BLOCK) \
		--output-path "$(shell pwd)/backup_$(shell printf '%07d' $(FROM_BLOCK))-$(shell printf '%07d' $(TO_BLOCK)).jsonl"

    # Update metadata
	@cat metadata.json | jq -a '.latest_block_height = $(TO_BLOCK)' > /tmp/aa.json
	@mv /tmp/aa.json metadata.json


fetch-all:
	@for i in `seq $(FROM_BLOCK) $(MAX_INTERVAL) $(LATEST_BLOCK_HEIGHT)`; do \
		make -C . fetch FROM_BLOCK="$$i"; \
	done

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


join:
	@echo "Joining small backup files..."
	@prev_file=""; \
	for f in $$(ls backup_*.jsonl 2>/dev/null | sort); do \
		size=$$(stat -c%s "$$f"); \
		if [ -n "$$prev_file" ]; then \
			prev_size=$$(stat -c%s "$$prev_file"); \
			if [ $$((prev_size + size)) -lt 102400 ]; then \
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

extractor:
	go run -C "../$(EXTRACTOR_DIR)" . \
		-source-path "$(shell pwd)" \
		-output-dir "$(shell pwd)/extracted"

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
