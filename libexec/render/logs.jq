include "lib";
# domovyk logs: errors of one boot by group, then OOM kills, kernel events,
# suspend and the journal size (requirements 11.1, 11.2, 11.4). Times are UTC.

def lpad(n): tostring | if length >= n then . else (" " * (n - length)) + . end;
def when: if . == null then "?" else .[5:10] + " " + .[11:19] end;
def day: if . == null then "?" else .[0:10] + " " + .[11:16] end;
def oneline: gsub("[\n\t]"; " ");
def prio_name: ["emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"][.] // "?";
def group_name:
  [(if .unit then .unit + (if .user then " (user)" else "" end) else empty end),
   (.identifier // empty)]
  | if length == 0 then "?" else join(" / ") end;
def shown: 30;
def n(word): "\(.) \(word)\(if . == 1 then "" else "s" end)";

(.boot | "boot \(.offset // "?")"
  + (if .current then " (current)" else "" end)
  + (if .first then ": \(.first | day) to \(.last | day) UTC" else "" end)
  + (if .clean_shutdown == true then ", ended with a clean shutdown"
     elif .clean_shutdown == false then
       ", no clean shutdown" + (if .ended_in_suspend then " (never woke from suspend)" else "" end)
     else "" end)
  | fit),
(.groups as $g
  | if $g == null then "errors: unknown"
    elif ($g | length) == 0 then "errors: none of priority err or worse"
    else
      ("errors: \($g | map(.count) | add | n("entry") | sub("entrys"; "entries"))"
        + " in \($g | length | n("group")) of priority err or worse (times UTC)" | fit),
      ("  " + ("COUNT" | lpad(6)) + " " + ("PRIO" | pad(7)) + " " + ("UNIT / IDENTIFIER" | pad(36))
        + " " + ("FIRST" | pad(14)) + "  LAST"),
      ($g[:shown][]
        | ("  " + (.count | lpad(6)) + " " + (.priority | prio_name | pad(7)) + " "
            + (group_name | trunc(36) | pad(36)) + " " + (.first | when) + "  " + (.last | when) | fit),
          ("           " + (.message | oneline) | fit)),
      (if ($g | length) > shown
       then "  … \(($g | length) - shown) more groups: domovyk logs --json" else empty end)
    end),
(.oom_kills
  | if . == null then "OOM kills: unknown"
    elif length == 0 then "OOM kills: none"
    else "OOM kills: \(length)",
      (.[] | "  \(.time | when) \(.source | pad(13)) \(.process)"
        + (if .pid then " (pid \(.pid))" else "" end) | fit)
    end),
(.kernel
  | if . == null then "kernel warnings and oopses: unknown"
    elif .count == 0 then "kernel warnings and oopses: none"
    else "kernel warnings and oopses: \(.count)",
      (.events[] | "  \(.time | when) \(.kind | pad(10)) \(.message | oneline)" | fit),
      (if .count > (.events | length)
       then "  … \(.count - (.events | length)) more: domovyk logs --json" else empty end)
    end),
(.suspend
  | if . == null then "suspend: unknown"
    else "suspend: \(.cycles | n("cycle")), \(.resumes | n("resume")), \(.failed) failed",
      (.failures[] | "  \(.time | when) \(.source | pad(13)) \(.message | oneline)" | fit)
    end),
(.journal
  | "journal: " + (if .disk_usage_bytes == null then "disk usage unknown"
                   else "\(.disk_usage_bytes | human) on disk" end)
    + (if .boots then ", \(.boots | n("boot"))" else "" end)),
unavailable_lines
