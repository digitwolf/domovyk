# Field-level shape of domovyk.hw.v1 (requirement 14.3, 14.4). True for a
# valid document. battery is null when the Host has no battery; otherwise it
# lists the system batteries, with capacities in µWh (unit "uWh") or µAh
# ("uAh"). firmware and machine carry only vendor, version and model.
def str_or_null: . == null or type == "string";
def num_or_null: . == null or type == "number";

.schema == "domovyk.hw.v1"
and (.cpu | . == null or ((.model | str_or_null) and (.sockets | num_or_null)
  and (.cores | num_or_null) and (.threads | type == "number")))
and (.gpus | . == null or (type == "array" and all(.[];
  (.slot | type == "string") and (.class | str_or_null) and (.vendor | str_or_null)
  and (.vendor_id | . == null or test("^[0-9a-f]{4}$")) and (.device | str_or_null)
  and (.device_id | . == null or test("^[0-9a-f]{4}$")) and (.driver | str_or_null)
  and (.modules | type == "array"))))
and (.memory_bytes | num_or_null)
and (.battery | . == null or (type == "array" and length > 0 and all(.[];
  (.name | type == "string") and (.unit | . == null or IN("uWh", "uAh"))
  and (.design | num_or_null) and (.full | num_or_null) and (.health_percent | num_or_null)
  and (.capacity_percent | num_or_null) and (.status | str_or_null)
  and (.cycle_count | num_or_null) and (.technology | str_or_null))))
and (.firmware | . == null or (keys == ["vendor", "version"]))
and (.machine | . == null or (keys == ["model", "vendor"]))
