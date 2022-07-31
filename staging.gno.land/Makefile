fetch:
	gnotxport export --remote staging.gno.land:36657
	wc -l txexport.log
	tail -n 1 txexport.log

stats:
	echo "# staging.gno.land" > README.md
	echo >> README.md

	echo "## addpkgs" >> README.md
	echo '```' >> README.md
	cat txexport.log | jq '.msg[].package.Path' | sort | uniq -c | sort -n >> README.md
	echo '```' >> README.md
	echo >> README.md

	echo "## top realm calls" >> README.md
	echo '```' >> README.md
	cat txexport.log | jq '.msg[].pkg_path' | sort | uniq -c | sort -n >> README.md
	echo '```' >> README.md
	echo >> README.md
