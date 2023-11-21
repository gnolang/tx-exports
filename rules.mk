
fetch:
	@echo "Backup from: $(FROM_BLOCK) to $(TO_BLOCK)"
	go run github.com/gnolang/tx-archive/cmd backup \
		--remote $(REMOTE) \
		--legacy=true \
		--from-block $(FROM_BLOCK) \
		--to-block   $(TO_BLOCK) \
		--output-path backup_$(shell printf '%06d' $(FROM_BLOCK))-$(TO_BLOCK).jsonl

    # Update metadata
	@cat metadata.json | jq -a '.latest_block_height = $(TO_BLOCK)' > /tmp/aa.json
	@mv /tmp/aa.json metadata.json


fetch-all:
	@for i in `seq $(FROM_BLOCK) $(MAX_INTERVAL) $(TO_BLOCK)`; do \
		make -C . fetch; \
	done

stats:
	echo "# $(REMOTE)" > README.md
	echo >> README.md

	echo "## TXs" >> README.md
	echo '```' >> README.md
	cat txexport-*.log | wc -l >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## addpkgs" >> README.md
	echo '```' >> README.md
	cat txexport-*.log | jq '.msg[].package.Path' | sort | uniq -c | sort -n >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top realm calls" >> README.md
	echo '```' >> README.md
	cat txexport-*.log | jq '.msg[].pkg_path' | sort | uniq -c | sort -n >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top faucet requesters" >> README.md
	echo '```' >> README.md
	cat txexport*.log | jq -r '.msg[] | select(.["@type"]=="/bank.MsgSend") | select(.["from_address"]=="g127jydsh6cms3lrtdenydxsckh23a8d6emqcvfa") | .to_address + " " + .amount' | sed 's/ugnot$$//' | awk 'NR == 1 {next} {a[$$1] += $$2} {b[$$1] += 1} END {for (i in a) {if (a[i] >= 500000000){printf "%-15s\t%s\t%s\n", i, b[i], a[i]}}}' | sort -rnk2 >> README.md
	echo '```' >> README.md
	echo >> README.md

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
