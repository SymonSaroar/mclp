# Adds mclp.dtsi next to the project's system-user.dtsi (same mechanism as meta-user's device-tree-sdt.inc)
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://mclp.dtsi"
EXTRA_DT_INCLUDE_FILES:append:linux = " mclp.dtsi"
EXTRA_DT_INCLUDE_FILES:append:linux-gnueabi = " mclp.dtsi"
