SUMMARY = "mclp console and register access over UIO"
DESCRIPTION = "mclp: weighing, calibration, raw capture, AD7190 self-test and the PL loopback BIST, \
with a decoded register trace (-t). Shares sw/common with the bare-metal console."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# The sources are the repository's: sw/common (shared with the bare-metal console) and sw/linux/mclp
FILESEXTRAPATHS:prepend := "${MCLP_SW_DIR}:${THISDIR}/files:"
SRC_URI = "file://common/ file://linux/mclp/ file://mclp.init file://mclp-uio.conf"
S = "${WORKDIR}/linux/mclp"
# common/ is outside ${S}: map its paths in the debug info too (buildpaths QA)
DEBUG_PREFIX_MAP:append = " -fdebug-prefix-map=${WORKDIR}/common=${TARGET_DBGSRC_DIR}/common \
                            -fmacro-prefix-map=${WORKDIR}/common=${TARGET_DBGSRC_DIR}/common"

inherit update-rc.d
INITSCRIPT_NAME = "mclp"
INITSCRIPT_PARAMS = "defaults 90"

RDEPENDS:${PN} += "kernel-module-uio-pdrv-genirq"

do_compile() {
	oe_runmake COMMON=${WORKDIR}/common
}

do_install() {
	oe_runmake install COMMON=${WORKDIR}/common DESTDIR=${D}
	install -d ${D}${sysconfdir}/init.d
	install -m 0755 ${WORKDIR}/mclp.init ${D}${sysconfdir}/init.d/mclp
	install -d ${D}${sysconfdir}/modprobe.d
	install -m 0644 ${WORKDIR}/mclp-uio.conf ${D}${sysconfdir}/modprobe.d/mclp-uio.conf
}
