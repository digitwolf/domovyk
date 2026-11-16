# Field-level shape of domovyk.perf.v1 (requirement 12). True for a valid
# document. boot and sample are null unless --boot or --sample was given.
def num: type == "number";
def num_or_null: . == null or type == "number";
def str_or_null: . == null or type == "string";
def psi: . == null or ((.avg10 | num) and (.avg60 | num) and (.avg300 | num) and (.total_us | num));
def procs: . == null or (type == "array" and length <= 10 and all(.[];
  (.pid | num) and (.uid | num) and (.command | type == "string") and (.cpu_percent | num)
  and (.rss_bytes | num) and (.memory_percent | num_or_null)));

.schema == "domovyk.perf.v1"
and (.load | . == null or ((.avg1 | num) and (.avg5 | num) and (.avg15 | num)
  and (.running | num) and (.total | num)))
and (.cpu_count | num_or_null)
and (.memory | . == null or ((.total_bytes | num) and (.available_bytes | num)
  and (.used_bytes | num) and (.used_percent | num_or_null)))
and (.swap | . == null or ((.total_bytes | num) and (.free_bytes | num) and (.used_bytes | num)
  and (.used_percent | num_or_null) and (.devices | type == "array" and all(.[];
    (.name | type == "string") and (.type | type == "string") and (.size_bytes | num)
    and (.used_bytes | num)))))
and (.zram | . == null or (type == "array" and all(.[]; (.device | type == "string")
  and (.disksize_bytes | num) and (.algorithm | str_or_null) and (.orig_data_bytes | num_or_null)
  and (.compr_data_bytes | num_or_null) and (.mem_used_bytes | num_or_null))))
and (.pressure | . == null or (type == "object" and (keys == ["cpu", "io", "memory"])
  and all(.[]; . == null or ((.some | psi) and (.full | psi)))))
and (.top_cpu | procs)
and (.top_memory | procs)
and (.top_cpu | . == null or (map(.cpu_percent) | . == (sort | reverse)))
and (.top_memory | . == null or (map(.rss_bytes) | . == (sort | reverse)))
and (.thermal | type == "array" and all(.[]; (.zone | type == "string") and (.type | str_or_null)
  and (.celsius | num_or_null)))
and (.throttling | . == null or ((.source | IN("sysfs", "kernel-log")) and (.events | num)
  and (.core_events | num_or_null) and (.package_events | num_or_null)
  and (.cpus_throttled | num_or_null)))
and (.power_profile | str_or_null)
and (.boot | . == null or ((.finished | type == "boolean") and (.total_seconds | num_or_null)
  and (.phases | . == null or (type == "object" and all(.[]; num_or_null)))
  and (.target | str_or_null) and (.target_seconds | num_or_null) and (.message | str_or_null)
  and (.slowest | . == null or (type == "array" and length <= 10 and all(.[];
    (.unit | type == "string") and (.unit | endswith(".device") | not) and (.seconds | num))))))
and (.sample | . == null or ((.seconds | num) and .seconds >= 1 and .seconds <= 10
  and (.cpu_busy_percent | num_or_null) and (.cpu_iowait_percent | num_or_null)
  and (.disks | type == "array" and all(.[]; (.device | type == "string")
    and (.util_percent | num and . >= 0 and . <= 100) and (.read_bytes_per_s | num)
    and (.write_bytes_per_s | num)))))
