SUMMARY = "MCLP console and REST/MQTT service over UIO"
DESCRIPTION = "mclp: weighing, calibration, raw capture, AD7190 self-test and the PL loopback BIST, \
with a decoded register trace (-t). mclpd: the same commands and live readings over HTTPS (REST) and \
MQTT with TLS. Both share sw/common with the bare-metal console."
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-3.0-only;md5=c79ff39f19dfec6d293b95dea7b07891"

# The sources are the repository's: sw/common (shared with the bare-metal console) and sw/linux/mclp
FILESEXTRAPATHS:prepend := "${MCLP_SW_DIR}:${THISDIR}/files:"
SRC_URI = "file://common/ file://linux/mclp/ file://mclp.init file://mclp-uio.conf file://mclpd.conf"
S = "${WORKDIR}/linux/mclp"
# common/ is outside ${S}: map its paths in the debug info too (buildpaths QA)
DEBUG_PREFIX_MAP:append = " -fdebug-prefix-map=${WORKDIR}/common=${TARGET_DBGSRC_DIR}/common \
                            -fmacro-prefix-map=${WORKDIR}/common=${TARGET_DBGSRC_DIR}/common"

DEPENDS = "libmicrohttpd mosquitto cjson libxcrypt"

inherit update-rc.d
INITSCRIPT_NAME = "mclp"
INITSCRIPT_PARAMS = "defaults 90"

# openssl-bin: the first-boot HTTPS certificate and `openssl passwd -6` for /etc/mclp/users
RDEPENDS:${PN} += "kernel-module-uio-pdrv-genirq openssl-bin"
CONFFILES:${PN} = "${sysconfdir}/mclp/mclpd.conf"

do_compile() {
	oe_runmake COMMON=${WORKDIR}/common
}

do_install() {
	oe_runmake install COMMON=${WORKDIR}/common DESTDIR=${D}
	install -d ${D}${sysconfdir}/init.d ${D}${sysconfdir}/modprobe.d ${D}${sysconfdir}/mclp
	install -m 0755 ${WORKDIR}/mclp.init ${D}${sysconfdir}/init.d/mclp
	install -m 0644 ${WORKDIR}/mclp-uio.conf ${D}${sysconfdir}/modprobe.d/mclp-uio.conf
	install -m 0600 ${WORKDIR}/mclpd.conf ${D}${sysconfdir}/mclp/mclpd.conf
}
