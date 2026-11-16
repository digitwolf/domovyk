include "lib";
# domovyk logs --unit: the last entries of one unit, newest last (requirement 11.3).

def oneline: gsub("[\n\t]"; " ");
def prio_name: ["emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"][.] // "?";

(.unit as $u
  | if (.entries | length) == 0 then "no journal entries for \($u.name)" | fit
    else "\($u.name) (\($u.scope // "?") unit"
      + (if $u.boot != null then ", boot \($u.boot)" else "" end)
      + "): \(.entries | length) entries, newest last (times UTC)" | fit
    end),
(.entries[]
  | "\(.time | .[0:10] + " " + .[11:19]) \(.priority | prio_name | pad(7)) "
    + "\(.identifier // "?")" + (if .pid then "[\(.pid)]" else "" end)
    + ": \(.message | oneline)"
  | fit),
unavailable_lines
