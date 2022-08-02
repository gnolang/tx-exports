fetch:
	gnotxport export --remote test1.gno.land:36657
	wc -l txexport.log
	tail -n 1 txexport.log
	rm -f txexport.log.gz
	gzip -k txexport.log

stats:
	echo "# test1.gno.land" > README.md
	echo >> README.md

	echo "## TXs" >> README.md
	echo '```' >> README.md
	zcat txexport.log.gz | wc -l >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## addpkgs" >> README.md
	echo '```' >> README.md
	zcat txexport.log.gz | jq '.msg[].package.Path' | sort | uniq -c | sort -n >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top realm calls" >> README.md
	echo '```' >> README.md
	zcat txexport.log.gz | jq '.msg[].pkg_path' | sort | uniq -c | sort -n >> README.md
	echo '```' >> README.md
	echo >> README.md
