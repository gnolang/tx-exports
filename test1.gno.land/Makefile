fetch:
	gnotxport export --remote test1.gno.land:36657
	wc -l txexport.log
	tail -n 1 txexport.log
	split --lines=10000 --additional-suffix=.log txexport.log txexport-

stats:
	echo "# test1.gno.land" > README.md
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
