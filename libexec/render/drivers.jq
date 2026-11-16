include "lib";
# domovyk drivers: devices and their drivers, ubuntu-drivers candidates, DKMS,
# Secure Boot and MOK, fwupd devices (requirements 9.1-9.5).

def dash: if . == null or . == "" then "-" else tostring end;
def yesno: if . == true then "yes" elif . == false then "no" else "unknown" end;

(.devices as $d
  | "devices: \([$d[] | select(.bus == "pci")] | length) PCI, \([$d[] | select(.bus == "usb")] | length) USB;"
    + " \([$d[] | select(.driver == null)] | length) without a driver",
  (if ($d | length) > 0 then
     "  BUS ADDRESS       ID         DRIVER                 NAME",
     ($d[] | "  \(.bus | pad(3)) \(.address | pad(13)) \(.vendor_id):\(.product_id)  "
       + "\(.driver | dash | trunc(22) | pad(22)) \(.name // .vendor // "?")"
       # The class helps to tell what a device without a driver is.
       + (if .driver == null and .class_name then " (\(.class_name))" else "" end) | fit)
   else empty end)),
(.candidates
  | if . == null then "candidates (ubuntu-drivers): unknown"
    elif length == 0 then "candidates (ubuntu-drivers): none"
    else "candidates (ubuntu-drivers):",
      (.[]
        | ((if .installed then "installed \(.version | dash)" else "not installed" end) | trunc(40)) as $state
        | "  \(.package | pad(32)) "
          + (if .recommended then ($state | pad(40)) + " recommended" else $state end) | fit)
    end),
(.dkms
  | if . == null then "dkms: unknown"
    elif (.modules | length) == 0 then "dkms: no modules"
    else "dkms (running kernel \(.kernel)):",
      (.modules[]
        | ("  \("\(.module)/\(.version)" | trunc(40) | pad(40)) \(.kernel | dash | pad(26)) \(.state)"
            + (if .detail then " (\(.detail))" else "" end) | fit),
          (if .log then "      build log: \(.log)" | fit else empty end))
    end),
(.secure_boot
  | "secure boot: \(.state); MOK enrolment pending: \(.mok_pending | yesno)"
    + (if .mok_pending == true then " (\(.mok_new_keys) key\(if .mok_new_keys == 1 then "" else "s" end))"
       else "" end)),
(.firmware_devices
  | if . == null then "firmware (fwupd): unknown"
    elif length == 0 then "firmware (fwupd): no devices"
    else "firmware (fwupd): \(length) devices",
      (.[] | "  \(.name | dash | trunc(44) | pad(44)) \(.vendor | dash | trunc(18) | pad(18)) "
        + (if .updatable then "\(.version | dash | trunc(22) | pad(22)) updatable"
           else .version | dash | trunc(22) end) | fit)
    end),
unavailable_lines
