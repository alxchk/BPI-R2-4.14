#!/bin/sh

set -e

SELF=`readlink -f "$0"`
OOT=`dirname "$SELF"`
KDIR=`readlink -f "$OOT/../"`

OPENSSL_DEBIAN_1_0_VER=${OPENSSL_DEBIAN_1_0_VER:-"1.0.2s-1~deb9u1"}
OPENSSL_DEBIAN_1_0_URL="http://ftp.us.debian.org/debian/pool/main/o/openssl1.0/libssl1.0.2_${OPENSSL_DEBIAN_1_0_VER}_armel.deb"
OPENSSL_DEBIAN_1_0_DEV_URL="http://ftp.us.debian.org/debian/pool/main/o/openssl1.0/libssl1.0-dev_${OPENSSL_DEBIAN_1_0_VER}_armel.deb"

DIST=${DIST:-../../bananapi-image}
DIST=`readlink -f "$DIST"`

CHOST=${CHOST:-armv7a-hardfloat-linux-gnueabi}
CROSS_COMPILE=${CHOST}-
CC=${CROSS_COMPILE}gcc

echo "{ CHOST: ${CHOST} }"

KMAKE_VARS="${KMAKE_VARS} INSTALL_MOD_PATH=${DIST} ARCH=arm CROSS_COMPILE=${CROSS_COMPILE}"
KMAKE_VARS="${KMAKE_VARS} INSTALL_HDR_PATH=${DIST}/usr/src/linux"

KMAKE="make ${KMAKE_VARS} -C ${KDIR}"

if [ ! -f ${KDIR}/.config ]; then
    echo "[+] Copy default config"
    cp -vf ${OOT}/bananapi_r2_config ${KDIR}/.config
fi

${KMAKE} oldconfig

KVER=`${KMAKE} -sC "$KDIR" kernelrelease`

echo "BUILD: $KVER to $DIST (DIST)"
rm -rf ${DIST}
mkdir -p ${DIST}/{boot,lib/firmware}

echo "[+] Copy WIFI firmware & config"
cp -a ${OOT}/mediatek ${DIST}/lib/firmware/

echo "[+] Copy SATA firmware & flasher"
mkdir -p ${DIST}/sbin
cp ${OOT}/ASM1061/ahci420g.rom ${DIST}/lib/firmware/
cp ${OOT}/ASM1061/106flash ${DIST}/sbin/

echo "[+] Build kernel"
${KMAKE} -j4

echo "[+] Build u-boot image (zImage + dtb)"
cat ${KDIR}/arch/arm/boot/{zImage,dts/mt7623n-bananapi-bpi-r2.dtb} \
    > ${KDIR}/arch/arm/boot/zImage-dtb
mkimage -A arm -O linux -T kernel -C none -a 80008000 -e 80008000 \
    -n "Linux" -d ${KDIR}/arch/arm/boot/zImage-dtb ${DIST}/boot/uImage

echo "[+] Install modules"
${KMAKE} modules_install

echo "[+] Install headers"
${KMAKE} headers_install

echo "[+] Fix symlinks"
rm -f "${DIST}/lib/modules/$KVER/build"
rm -f "${DIST}/lib/modules/$KVER/source"

ln -s ../../../usr/src/linux "${DIST}/lib/modules/$KVER/build"
ln -s ../../../usr/src/linux "${DIST}/lib/modules/$KVER/source"

echo "{ BUILD OOT MODULES & TOOLS }"

echo "[+] Build AUFS4"
AUFS4_DIR=${OOT}/aufs4-standalone
make -C ${AUFS4_DIR} KDIR=${KDIR} ${KMAKE_VARS} DESTDIR=${DIST} aufs.ko
make -C ${AUFS4_DIR} KDIR=${KDIR} ${KMAKE_VARS} DESTDIR=${DIST} install

echo "[+] Build cryptodev"
${KMAKE} -C ${OOT}/cryptodev-linux KERNEL_DIR=${KDIR}
${KMAKE} -C ${OOT}/cryptodev-linux KERNEL_DIR=${KDIR} DESTDIR=${DIST} prefix=/usr \
    MAKE="make INSTALL_MOD_PATH=${DIST}" install

echo "[+] Build libmnl (wireguard wg dep)"
cd ${OOT}/libmnl
./autogen.sh
./configure --enable-static --host=${CHOST} --prefix=/usr
make
make DESTDIR=${DIST} install
cd -

echo "[+] Build wireguard module"
${KMAKE} M=${OOT}/WireGuard/src modules
${KMAKE} M=${OOT}/WireGuard/src modules_install

echo "[+] Build wireguard cli tool"
make -C ${OOT}/WireGuard/src/tools \
    PLATFORM=banana \
    LDLIBS="${DIST}/usr/lib/libmnl.a" \
    CC="${CC} -O2 -I${DIST}/usr/include"
    
make -C ${OOT}/WireGuard/src/tools \
    PLATFORM=linux \
    DESTDIR=${DIST} \
    WITH_WGQUICK=yes WITH_SYSTEMDUNITS=yes \
    install

echo "[+] Build exfat kernel module"
${KMAKE} M=${OOT}/exfat-nofuse CONFIG_EXFAT_FS=m modules
${KMAKE} M=${OOT}/exfat-nofuse CONFIG_EXFAT_FS=m modules_install

echo "[-] Remove libmnl.a"
rm -rf ${DIST}/usr/lib

echo "[+] Build af_alg openssl (1.0.2) engine <manually>"
cd ${OOT}/af_alg/src
if [ ! -d openssl_dist ]; then
    mkdir openssl_dist

    echo "[D] Download openssl 1.0.2 libs (${OPENSSL_DEBIAN_1_0_URL})"
    wget "${OPENSSL_DEBIAN_1_0_URL}" -O openssl_dist/openssl1_0.deb
    echo "[D] Download openssl 1.0.2 headers (${OPENSSL_DEBIAN_1_0_DEV_URL})"
    wget "${OPENSSL_DEBIAN_1_0_DEV_URL}" -O openssl_dist/openssl-dev1_0.deb

    dpkg -x openssl_dist/openssl1_0.deb openssl_dist/root1_0
    dpkg -x openssl_dist/openssl-dev1_0.deb openssl_dist/root1_0
fi

OPENSSL_1_0_ROOT=`readlink -f openssl_dist/root1_0`
OPENSSL_1_0_CFLAGS="-I${OPENSSL_1_0_ROOT}/usr/include -I${OPENSSL_1_0_ROOT}/usr/include/arm-linux-gnueabi"
OPENSSL_1_0_LIBS="${OPENSSL_1_0_ROOT}/usr/lib/arm-linux-gnueabi/libcrypto.so.1.0.2"
OPENSSL_1_0_ENGINES=${DIST}/usr/lib/arm-linux-gnueabihf/openssl-1.0.2/engines
OPENSSL_1_0_ENGINE=libafalg.so

if [ ! -d ${OPENSSL_1_0_ENGINES} ]; then
    mkdir -p ${OPENSSL_1_0_ENGINES}
fi

set -x

${CC} -O2 -pipe -shared -o ${OPENSSL_1_0_ENGINES}/${OPENSSL_1_0_ENGINE} \
    ciphers.c digests.c e_af_alg.c \
    -I${DIST}/usr/src/linux/include \
    ${OPENSSL_1_0_CFLAGS} ${OPENSSL_1_0_LIBS} \
    -Wl,-no-undefined -Wl,-soname,${OPENSSL_1_0_ENGINE}

cd -

set +x

echo "[+] Build package"
cp -r ${OOT}/DEBIAN ${DIST}
if [ -f ${DIST}.deb ]; then
    rm -f ${DIST}.deb
fi
dpkg-deb --root-owner-group -b ${DIST} ${DIST}.deb

echo "[+] Cleanup"
rm -rf ${DIST}

echo "[+] DEB: ${DIST}.deb"
