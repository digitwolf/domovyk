# Text view of domovyk.services-status.v1 (requirement 14.2). Every line is
# cut to 100 columns by fit.
include "lib";

def when: if . == null then "?" else sub("T"; " ") | sub("Z$"; "") end;
def row(k; v): "  \(k | pad(11)) \(v)";

(
  (.unit | if . == null then "unit status unknown"
    else "\(.name) (\(.scope)): \(.active // "?") (\(.sub // "?")) since \(.since | when)",
      (if .description then "  \(.description)" else empty end),
      row("loaded"; .load // "?"),
      row("enablement"; (.enablement // "none") + (if .preset then " (preset \(.preset))" else "" end)),
      row("result"; .result // "?"),
      row("main pid"; .main_pid // "none"),
      row("memory"; if .memory_bytes == null then "not counted" else .memory_bytes | human end),
      row("restarts"; .restarts // "n/a"),
      (if .fragment then row("unit file"; .fragment) else empty end),
      (.journal | if . == null then "journal: not readable"
        elif length == 0 then "journal: no lines"
        else "journal (last \(length)):",
          (.[] | "  \(.time | when) \(.identifier // "?")\(if .pid then "[\(.pid)]" else "" end): "
            + (.message // "(message not shown)" | tostring | gsub("[\\n\\t]"; " ")))
        end)
    end)
  | fit
),
unavailable_lines
