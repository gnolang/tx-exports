#!/usr/bin/env bash
# Exercises .github/scripts/backup-patch.sh, which carries an exporter run's
# results from its read-only export job to the job that commits them:
# - pack writes the changes of the files a run writes in its chain dir (backups,
#   metadata.json, README.md, extracted/), byte for byte, and leaves out any
#   other change;
# - apply stages such a patch in another checkout;
# - apply refuses, changing nothing, a patch that touches any other path or
#   writes anything but a regular file (a symlink, a gitlink).
# Usage: tests/backup-patch.sh   (needs git)
set -uo pipefail
root=$(cd -- "$(dirname "$0")/.." >/dev/null && pwd) || exit 1
script=$root/.github/scripts/backup-patch.sh
fail=0
ok() { echo "ok   - $1"; }
ko() {
  echo "FAIL - $1"
  fail=1
}
# git in the scratch repos, with an identity that no config file carries
g() { git -c user.name=test -c user.email=test@example.invalid "$@"; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

# origin: a repo with a chain dir as an exporter run finds it
mkdir -p "$work/origin/chain.gno.land/extracted/r/demo/old" "$work/origin/other.gno.land" || exit 1
cd "$work/origin" || exit 1
g init -q . || exit 1
printf '*/extracted/** -text\n' >.gitattributes
printf 'all:\n' >rules.mk
printf 'SHORTNAME = chain\n' >chain.gno.land/Makefile
printf '{"latest_block_height": 10}\n' >chain.gno.land/metadata.json
printf '# stats\n' >chain.gno.land/README.md
printf 'line1\n' >chain.gno.land/backup_0000001-0000010.jsonl
printf 'old\r\n' >chain.gno.land/extracted/r/demo/old/old.gno
printf 'x\n' >other.gno.land/backup_0000001-0000010.jsonl
g add .gitattributes rules.mk chain.gno.land other.gno.land && g commit -q -m base || exit 1

clone() { g clone -q "$work/origin" "$work/$1"; }

# a run: a new backup, updated metadata and stats, a package dropped and one
# added (with CRLF bytes), next to changes the patch must leave out
clone export || exit 1
cd "$work/export/chain.gno.land" || exit 1
printf 'line2\n' >backup_0000011-0000020.jsonl
# tx-archive writes its backups executable, and CI commits them so
chmod +x backup_0000011-0000020.jsonl
printf '{"latest_block_height": 20}\n' >metadata.json
printf '# stats 2\n' >README.md
rm -r extracted/r/demo/old
mkdir -p extracted/r/demo/new temp-gno backup_sub
printf 'new\r\n\000' >extracted/r/demo/new/new.gno
printf 'SHORTNAME = evil\n' >Makefile
printf 'junk\n' >temp-gno/junk
printf 'nested\n' >backup_sub/x.jsonl
printf 'evil\n' >../rules.mk
cd "$work/export" || exit 1
if out=$(bash "$script" pack chain.gno.land "$work/run.patch" 2>&1); then
  ok "pack runs"
else
  ko "pack runs: $out"
fi

clone commit || exit 1
cd "$work/commit" || exit 1
if out=$(bash "$script" apply chain.gno.land "$work/run.patch" 2>&1); then
  ok "apply runs"
else
  ko "apply runs: $out"
fi
got=$(g diff --cached --name-status --no-renames | tr '\t' ' ' | LC_ALL=C sort | tr '\n' '|')
want='A chain.gno.land/backup_0000011-0000020.jsonl|A chain.gno.land/extracted/r/demo/new/new.gno|'
want+='D chain.gno.land/extracted/r/demo/old/old.gno|M chain.gno.land/README.md|M chain.gno.land/metadata.json|'
if [ "$got" = "$want" ]; then
  ok "apply stages the run's changes to the files it writes, and nothing else"
else
  ko "apply stages the run's changes to the files it writes, and nothing else: $got"
fi
if [ "$(g ls-files -s chain.gno.land/backup_0000011-0000020.jsonl | cut -d' ' -f1)" = 100755 ]; then
  ok "an executable backup keeps its mode"
else
  ko "an executable backup keeps its mode"
fi
if printf 'new\r\n\000' | cmp -s - chain.gno.land/extracted/r/demo/new/new.gno &&
  g show :chain.gno.land/extracted/r/demo/new/new.gno | cmp -s - <(printf 'new\r\n\000'); then
  ok "a file's bytes survive, CR and NUL included"
else
  ko "a file's bytes survive, CR and NUL included"
fi

# a run that changes nothing
clone idle || exit 1
cd "$work/idle" || exit 1
if bash "$script" pack chain.gno.land "$work/idle.patch" && [ ! -s "$work/idle.patch" ] &&
  (cd "$work/commit" && bash "$script" apply chain.gno.land "$work/idle.patch"); then
  ok "an idle run packs an empty patch, which applies as a no-op"
else
  ko "an idle run packs an empty patch, which applies as a no-op"
fi

# pack always writes the patch, empty on an idle run: a missing one means the
# hand-off between the jobs broke
clone missing || exit 1
cd "$work/missing" || exit 1
if bash "$script" apply chain.gno.land "$work/no-such.patch" >/dev/null 2>&1; then
  ko "apply fails on a missing patch: exited 0"
elif [ -n "$(g status --porcelain)" ]; then
  ko "apply fails on a missing patch, changing nothing"
else
  ok "apply fails on a missing patch, changing nothing"
fi

# evil <name> <shell> <what> [staged]: a patch of the changes <shell> makes in a
# fresh clone (staged by <shell> itself when `staged`), which apply must refuse
# on another fresh clone without changing it
evil() {
  clone "evil-$1" || return 1
  (
    cd "$work/evil-$1" && eval "$2" || exit 1
    [ "${4-}" = staged ] || g add -A . || exit 1
    g diff --cached --binary --no-renames
  ) >"$work/$1.patch" || return 1
  [ -s "$work/$1.patch" ] || {
    ko "apply refuses $3: the fixture patch is empty"
    return 1
  }
  clone "target-$1" || return 1
  cd "$work/target-$1" || return 1
  if out=$(bash "$script" apply chain.gno.land "$work/$1.patch" 2>&1); then
    ko "apply refuses $3: exited 0"
  elif [[ $out != *"backup-patch: refusing "* ]]; then
    ko "apply refuses $3, saying so: $out"
  elif [ -n "$(g status --porcelain)" ]; then
    ko "apply refuses $3, changing nothing: $(g status --porcelain | tr '\n' '|')"
  else
    ok "apply refuses $3, changing nothing"
  fi
}
evil rules 'printf "evil\n" >rules.mk' "a change outside the chain dir"
evil rootreadme 'printf "evil\n" >README.md' "a run's file name outside the chain dir"
evil rename 'g mv chain.gno.land/extracted/r/demo/old/old.gno planted.sh' "a rename out of the chain dir"
evil makefile 'printf "SHORTNAME = evil\n" >chain.gno.land/Makefile' "a change to the chain's Makefile"
evil other 'printf "y\n" >other.gno.land/backup_0000011-0000020.jsonl' "a change to another chain dir"
# backup_*.jsonl names a file directly in the chain dir, whose `*` must not
# reach into a subdir
evil nested 'mkdir chain.gno.land/backup_sub && printf "y\n" >chain.gno.land/backup_sub/x.jsonl' "a file in a subdir"
evil symlink 'ln -s /etc/passwd chain.gno.land/extracted/r/demo/link' "a symlink"
evil gitlink 'g update-index --add --cacheinfo 160000,$(g rev-parse HEAD),chain.gno.land/extracted/r/demo/sub' \
  "a gitlink" staged
evil mixed 'printf "{}\n" >chain.gno.land/metadata.json && printf "evil\n" >rules.mk' \
  "a patch mixing allowed and other changes"

# a refused path is printed on one line: a newline in it would let the rest
# read as a workflow command (::error, ::add-mask) in the commit job's log
clone newline || exit 1
cd "$work/newline" || exit 1
cat >"$work/newline.patch" <<'EOF'
diff --git "a/x\n::error title=forged::hello" "b/x\n::error title=forged::hello"
new file mode 100644
index 0000000..e69de29
EOF
out=$(bash "$script" apply chain.gno.land "$work/newline.patch" 2>&1)
if [[ $out != *"backup-patch: refusing "* ]]; then
  ko "a refused path is printed on one line: not refused: $out"
elif grep -q '^::' <<<"$out"; then
  ko "a refused path is printed on one line: $out"
else
  ok "a refused path is printed on one line"
fi

# the vetting diff failing must refuse the patch, not let it through unvetted:
# a git that fails only on --raw, applying the refused rules.mk patch
real_git=$(command -v git) || exit 1
mkdir "$work/shim" || exit 1
cat >"$work/shim/git" <<EOF
#!/bin/sh
case " \$* " in *" --raw "*) exit 1 ;; esac
exec "$real_git" "\$@"
EOF
chmod +x "$work/shim/git" || exit 1
clone vetfail || exit 1
cd "$work/vetfail" || exit 1
if PATH="$work/shim:$PATH" bash "$script" apply chain.gno.land "$work/rules.patch" >/dev/null 2>&1; then
  ko "apply refuses a patch its vetting diff failed on: exited 0"
elif [ -n "$(g status --porcelain)" ]; then
  ko "apply refuses a patch its vetting diff failed on, changing nothing"
else
  ok "apply refuses a patch its vetting diff failed on, changing nothing"
fi
exit $fail
