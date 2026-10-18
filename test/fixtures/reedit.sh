# The editor for the `cfg edit` terminal tests: the first time, it leaves a file that does
# not parse; the second time, one that does. A file beside the edited one counts the runs.
if [ -e "$1.count" ]; then
  printf 'a = 2\n' > "$1"
else
  : > "$1.count"
  printf 'a = [\n' > "$1"
fi
