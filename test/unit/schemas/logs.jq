# domovyk.logs.v1 field shapes (requirements 11.1, 11.2, 11.4). Run with
# jq -e -f after envelope.jq; true when every field has its documented type.
def time: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
def time_or_null: . == null or time;
def str_or_null: . == null or type == "string";
def bool_or_null: . == null or type == "boolean";
def int: type == "number" and . == floor;
def int_or_null: . == null or int;
def count: int and . >= 0;

.schema == "domovyk.logs.v1"
and (.boot | type == "object"
  and (.offset | int_or_null) and (.id | str_or_null)
  and (.first | time_or_null) and (.last | time_or_null)
  and (.current | bool_or_null)
  and (.clean_shutdown | bool_or_null) and (.ended_in_suspend | bool_or_null)
  # Only an earlier boot has a shutdown verdict.
  and (if .current == true then .clean_shutdown == null else true end))
# groups, oom_kills, kernel and suspend are null when journalctl is missing.
and (.groups | . == null or type == "array" and all(.[];
  (.unit | str_or_null) and (.user | type == "boolean") and (.identifier | str_or_null)
  and (.priority | int and . >= 0 and . <= 3)
  and (.count | count and . >= 1)
  and (.first | time) and (.last | time) and .first <= .last
  and (.message | type == "string")))
and (.oom_kills | . == null or type == "array" and all(.[];
  (.time | time) and (.source | IN("kernel", "systemd-oomd"))
  and (.process | type == "string") and (.pid | int_or_null) and (.message | type == "string")))
and (.kernel | . == null or type == "object" and (.count | count)
  and (.events | type == "array" and length <= 20 and all(.[];
    (.time | time)
    and (.kind | IN("panic", "lockup", "hung-task", "stall", "warning", "bug", "oops", "call-trace"))
    and (.message | type == "string"))))
and (.suspend | . == null or type == "object"
  and (.cycles | count) and (.resumes | count) and (.failed | count)
  and (.failures | type == "array" and length <= 20 and all(.[];
    (.time | time) and (.source | IN("kernel", "systemd-sleep")) and (.message | type == "string"))))
and (.journal | type == "object"
  and (.disk_usage_bytes | . == null or count) and (.boots | . == null or count))
