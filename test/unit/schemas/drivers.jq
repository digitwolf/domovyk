# domovyk.drivers.v1 field shapes (requirements 9.1-9.5). Run with jq -e -f
# after envelope.jq; true when every field has its documented type.
def str_or_null: . == null or type == "string";
def hex4: type == "string" and test("^[0-9a-f]{4}$");

.schema == "domovyk.drivers.v1"
and (.devices | type == "array" and all(.[];
  (.bus | IN("pci", "usb")) and (.address | type == "string" and length > 0)
  and (.vendor_id | hex4) and (.product_id | hex4)
  and (.class | str_or_null) and (.class_name | str_or_null)
  and (.vendor | str_or_null) and (.name | str_or_null) and (.driver | str_or_null)))
and (.candidates | . == null or (type == "array" and all(.[];
  (.package | type == "string" and test("^[a-z0-9][a-z0-9+.~-]+$"))
  and (.installed | type == "boolean") and (.recommended | type == "boolean")
  and (.version | str_or_null) and (.kernel_modules | str_or_null))))
and (.dkms | . == null or (type == "object"
  and (.kernel | type == "string")
  and (.modules | type == "array" and all(.[];
    (.module | type == "string") and (.version | type == "string")
    and (.kernel | str_or_null) and (.arch | str_or_null)
    and (.state | type == "string") and (.detail | str_or_null)
    and (.log | str_or_null)
    # 9.5: a failed build always names its make.log.
    and (if .state == "build-failed" then (.log | type == "string" and endswith("/make.log")) else true end)))))
and (.secure_boot | type == "object"
  and (.state | IN("enabled", "disabled", "unknown"))
  and (.mok_pending | . == null or type == "boolean")
  and (.mok_new_keys | . == null or (type == "number" and . >= 0)))
and (.firmware_devices | . == null or (type == "array" and all(.[];
  (.name | str_or_null) and (.vendor | str_or_null) and (.version | str_or_null)
  and (.plugin | str_or_null) and (.updatable | type == "boolean")
  and (keys - ["name", "vendor", "version", "plugin", "updatable"] == []))))
