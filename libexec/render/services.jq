# Text view of domovyk.services.v1 (requirement 14.1). Every line is cut to
# 100 columns by fit.
include "lib";

def when: if . == null then "?" else sub("T"; " ") | sub("Z$"; "") end;

def entry: "    \(.time | when) \(.identifier // "?")\(if .pid then "[\(.pid)]" else "" end): "
  + (.message // "(message not shown)" | tostring | gsub("[\\n\\t]"; " "));

def scope(title):
  if . == null then "\(title): unknown (see unavailable)"
  elif length == 0 then "\(title): none"
  else "\(title) (\(length)):",
    (.[] | "  \(.unit)  \(.active)/\(.sub)  result \(.result // "?")  since \(.since | when)",
      "    \(.description)",
      (.journal | if . == null then "    (journal not readable)"
        elif length == 0 then "    (no journal lines)"
        else .[] | entry end))
  end;

(
  (.failed_system | scope("failed system units")),
  (.failed_user | scope("failed user units")),
  (if ((.failed_system // []) + (.failed_user // []) | length) > 0
    then "", "next: domovyk services status <unit> [--user]" else empty end)
  | fit
),
unavailable_lines
