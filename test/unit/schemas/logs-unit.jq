# domovyk.logs-unit.v1 field shapes (requirement 11.3). Run with jq -e -f
# after envelope.jq; true when every field has its documented type.
def time: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");

.schema == "domovyk.logs-unit.v1"
and (.unit | type == "object"
  and (.name | type == "string" and length > 0)
  and (.scope | . == null or IN("system", "user"))
  and (.boot | . == null or (type == "number" and . == floor))
  and .limit == 200)
and (.entries | type == "array" and length <= 200
  and all(.[];
    (.time | time) and (.priority | type == "number" and . >= 0 and . <= 7)
    and (.identifier | . == null or type == "string")
    and (.pid | . == null or (type == "number" and . == floor))
    and (.message | type == "string"))
  # Newest last.
  and ([.[].time] == ([.[].time] | sort)))
and (if (.entries | length) == 0 then true else .unit.scope != null end)
