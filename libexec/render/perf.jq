# Text view of domovyk.perf.v1 (requirement 12). Every line is cut to 100
# columns by fit.
include "lib";

# fixed(d): a number with exactly d decimals (d is 1 or 2), "?" for null.
def fixed(d):
  if . == null then "?"
  else (if d == 1 then 10 else 100 end) as $m | (. * $m | round) as $n
    | ($n | fabs) as $a
    | (if $n < 0 then "-" else "" end) + "\(($a / $m) | floor)."
      + ("\($a % $m)" | if length < d then ("0" * (d - length)) + . else . end)
  end;
def r1: fixed(1);
def r2: fixed(2);
def pct: if . == null then "?" else "\(r1) %" end;
def secs: if . == null then "?" else "\(r1) s" end;
def lpad(n): tostring | if length >= n then . else (" " * (n - length)) + . end;

# wrap($w): joins strings with ", " into lines of at most $w columns.
def wrap($w):
  reduce .[] as $s ([];
    if length == 0 then [$s]
    elif (.[length - 1] + ", " + $s | length) <= $w then .[length - 1] += ", " + $s
    else . + [$s] end);

def head(s): s | pad(11);

def psi(n):
  "  \(n | pad(8)) "
  + (.[n] | if . == null then "?"
    else "some \(.some.avg10 | r2) \(.some.avg60 | r2) \(.some.avg300 | r2)"
      + (if .full then "   full \(.full.avg10 | r2) \(.full.avg60 | r2) \(.full.avg300 | r2)" else "" end)
    end);

def procs(title; col; val):
  if . == null then "\(title): unknown"
  else title,
    "  \("PID" | lpad(8)) \("UID" | lpad(6)) \(col | lpad(6)) \("RSS" | lpad(8))  COMMAND",
    (.[] | "  \(.pid | lpad(8)) \(.uid | lpad(6)) \(val | lpad(6)) \(.rss_bytes | human | lpad(8))  \(.command)")
  end;

(
  (.load | if . == null then head("load") + "unknown"
    else head("load") + "\(.avg1 | r2) \(.avg5 | r2) \(.avg15 | r2) (1, 5, 15 min), "
      + "\(.running)/\(.total) running" end)
  + (if .cpu_count then ", \(.cpu_count) CPUs" else "" end),

  (.memory | head("memory") + if . == null then "unknown"
    else "\(.used_bytes | human) used of \(.total_bytes | human) (\(.used_percent | pct)), "
      + "\(.available_bytes | human) available" end),

  (.swap | head("swap") + if . == null then "unknown"
    elif .total_bytes == 0 then "none"
    else "\(.used_bytes | human) used of \(.total_bytes | human) (\(.used_percent | pct))"
      + (if (.devices | length) > 0 then ": " + (.devices | map("\(.name) \(.type)") | join(", ")) else "" end)
    end),

  (.zram | head("zram") + if . == null then "unknown"
    elif length == 0 then "none"
    else map("\(.device) \(.algorithm // "?") \(.disksize_bytes | human): "
      + "\(.orig_data_bytes | human) stored in \(.mem_used_bytes | human)") | join(", ") end),

  (if .pressure == null then head("pressure") + "unknown"
    else head("pressure") + "% of time stalled, avg10 avg60 avg300",
      (.pressure | psi("cpu"), psi("memory"), psi("io"))
    end),

  "",
  (.top_cpu | procs("top cpu (ps: average since each process started)"; "CPU%"; .cpu_percent | r1)),
  "",
  (.top_memory | procs("top memory"; "MEM%"; .memory_percent | r1)),
  "",

  (.thermal | if length == 0 then head("thermal") + "no thermal zones"
    else (map("\(.type // .zone) \(.celsius | r1)C") | wrap(86)) as $l
      | (head("thermal") + $l[0]), ($l[1:][] | (" " * 11) + .) end),

  (.throttling | head("throttling") + if . == null then "unknown"
    elif .source == "sysfs" then
      "\(.events) events since boot (core \(.core_events), package \(.package_events); "
      + "\(.cpus_throttled) CPUs throttled)"
    else "\(.events) kernel log lines about throttling this boot" end),

  (head("power") + (.power_profile // "unknown")),

  (.boot | if . == null then empty
    elif .finished | not then "", head("boot") + "not finished: \(.message // "?")"
    else "",
      head("boot") + "\(.total_seconds | secs) total: "
        + (.phases | to_entries | map("\(.key) \(.value | secs)") | join(", ")),
      (if .target then (" " * 11) + "\(.target) reached after \(.target_seconds | secs) in userspace"
        else empty end),
      (if .slowest then "  slowest", (.slowest[] | "  \(.seconds | secs | lpad(9))  \(.unit)") else empty end)
    end),

  (.sample | if . == null then empty
    else "",
      head("sample") + "\(.seconds) s: CPU \(.cpu_busy_percent | pct) busy, "
        + "\(.cpu_iowait_percent | pct) iowait",
      (.disks[] | "  \(.device | pad(12)) util \(.util_percent | pct), "
        + "read \(.read_bytes_per_s | human)/s, write \(.write_bytes_per_s | human)/s")
    end)
  | fit
),
unavailable_lines
