# The Envelope every Fact_Output carries (requirement 4.3).
(.schema | type == "string" and test("^domovyk\\.[a-z-]+\\.v[0-9]+$"))
and (.generated | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
and (.host | type == "object" and has("codename") and has("release") and has("kernel"))
and (.unavailable | type == "array" and all(.[]; has("source") and (.reason | IN("missing", "permission", "timeout"))))
