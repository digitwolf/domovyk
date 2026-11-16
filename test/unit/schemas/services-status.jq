# Field-level shape of domovyk.services-status.v1 (requirement 14.2). True
# for a valid document. unit is null only when no service manager could be
# asked.
def str_or_null: . == null or type == "string";
def num_or_null: . == null or type == "number";
def entry: (.time | str_or_null) and (.priority | num_or_null) and (.identifier | str_or_null)
  and (.pid | num_or_null) and (.message | str_or_null);

.schema == "domovyk.services-status.v1"
and (.unit | . == null or (
  (.name | type == "string") and (.scope | IN("system", "user"))
  and (.description | str_or_null) and (.load | str_or_null) and (.active | str_or_null)
  and (.sub | str_or_null) and (.result | str_or_null) and (.enablement | str_or_null)
  and (.preset | str_or_null) and (.main_pid | . == null or (type == "number" and . > 0))
  and (.memory_bytes | num_or_null) and (.restarts | num_or_null)
  and (.since | . == null or test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
  and (.fragment | str_or_null)
  and (.journal | . == null or (type == "array" and length <= 20 and all(.[]; entry)))))
