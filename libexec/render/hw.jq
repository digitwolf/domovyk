# Text view of domovyk.hw.v1 (requirement 14.3, 14.4). Every line is cut to
# 100 columns by fit.
include "lib";

def row(k; v): "\(k | pad(9)) \(v)";
# A capacity in µWh or µAh as Wh or Ah with two decimals.
def cap(u): if . == null then "?"
  else "\((. / 10000 | round) / 100) \(if u == "uWh" then "Wh" elif u == "uAh" then "Ah" else "?" end)" end;
def orq: if . == null then "?" else . end;

(
  (.cpu | row("cpu"; if . == null then "unknown"
    else "\(.model // "unknown model") (\(if .cores then "\(.cores) cores, " else "" end)\(.threads) threads"
      + (if (.sockets // 1) > 1 then ", \(.sockets) sockets" else "" end) + ")" end)),

  row("memory"; .memory_bytes | if . == null then "unknown" else human end),

  (.gpus | if . == null then row("gpu"; "unknown")
    elif length == 0 then row("gpu"; "none found")
    else .[] | row("gpu"; (if .vendor or .device then "\(.vendor // "?") \(.device // "?")"
          else "PCI display device" end)
        + " [\(.vendor_id // "?"):\(.device_id // "?")]"),
      row(""; "driver \(.driver // "none")"
        + (if (.modules | length) > 0 then ", modules \(.modules | join(", "))" else "" end)
        + " at \(.slot)")
    end),

  (.battery | if . == null then row("battery"; "none")
    else .[] | .unit as $u | row("battery"; "\(.name): health \(.health_percent | orq) %, "
      + "\(.full | cap($u)) of \(.design | cap($u)) design"
      + (if .capacity_percent then ", \(.capacity_percent) % charged" else "" end)
      + (if .status then ", \(.status | ascii_downcase)" else "" end)
      + (if .cycle_count then ", \(.cycle_count) cycles" else "" end))
    end),

  (.firmware | row("firmware"; if . == null then "unknown" else "\(.vendor | orq) \(.version | orq)" end)),
  (.machine | row("machine"; if . == null then "unknown" else "\(.vendor | orq) \(.model | orq)" end))
  | fit
),
unavailable_lines
