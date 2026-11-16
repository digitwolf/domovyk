# Field-level shape of domovyk.services.v1 (requirement 14.1). True for a
# valid document. A scope is null when its service manager could not be
# asked; a unit's journal is null when the journal could not be read.
def str_or_null: . == null or type == "string";
def entry: (.time | str_or_null) and (.priority | . == null or type == "number")
  and (.identifier | str_or_null) and (.pid | . == null or type == "number")
  and (.message | str_or_null);
def units: . == null or (type == "array" and all(.[];
  (.unit | type == "string") and (.load | type == "string") and (.active | type == "string")
  and (.sub | type == "string") and (.description | type == "string")
  and (.result | str_or_null)
  and (.since | . == null or test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
  and (.journal | . == null or (type == "array" and length <= 10 and all(.[]; entry)))));

.schema == "domovyk.services.v1"
and (.failed_system | units)
and (.failed_user | units)
