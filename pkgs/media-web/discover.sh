command -v ss >/dev/null 2>&1 || echo "media-web: ss is missing on $(uname -n)" >&2
listeners=$(ss -ltnpH 2>/dev/null)

[ -n "$listeners" ] && awk '{
  port = $4; sub(/.*:/, "", port)
  addr = $4; sub(/:[^:]*$/, "", addr)
  proc = ""; pid = ""
  if (match($0, /users:\(\("[^"]*",pid=[0-9]+/)) {
    s = substr($0, RSTART, RLENGTH)
    split(s, parts, "\"")
    proc = parts[2]
    pid = s; sub(/.*pid=/, "", pid)
  }
  printf "L\t%s\t%s\t%s\t%s\n", port, addr, proc, pid
}' <<<"$listeners"

grep -o 'pid=[0-9]*' <<<"$listeners" | sort -u | while IFS='=' read -r _ pid; do
  unit=$(grep -o '[^/]*\.service' "/proc/$pid/cgroup" 2>/dev/null | tail -n 1)
  [ -n "$unit" ] && printf 'U\t%s\t%s\n' "$pid" "${unit%.service}"
done

if command -v docker >/dev/null 2>&1; then
  docker ps --format '{{.Names}}	{{.Ports}}' 2>/dev/null | awk -F '\t' '{
    n = split($2, ports, ", ")
    for (i = 1; i <= n; i++) {
      if (ports[i] !~ /->[0-9-]+\/tcp$/) continue
      host = ports[i]; sub(/->.*/, "", host)
      range = host; sub(/.*:/, "", range)
      addr = host; sub(/:[^:]*$/, "", addr)
      split(range, r, "-")
      last = (r[2] == "") ? r[1] : r[2]
      for (p = r[1] + 0; p <= last + 0; p++) printf "C\t%s\t%s\t%s\n", p, addr, $1
    }
  }'
fi
