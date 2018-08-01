#!/bin/bash
# Based on a test script from avsm/ocaml repo https://github.com/avsm/ocaml
# Adapted from https://www.tomaz.me/2013/12/02/running-travis-ci-tests-on-arm.html
# Adapted from https://github.com/PJK/libcbor/blob/master/.travis-qemu.sh
# Adapted from https://gist.github.com/oznu/b5efd7784e5a820ec3746820f2183dc0
# Adapted from https://blog.lazy-evaluation.net/posts/linux/debian-armhf-bootstrap.html
# Adapted from https://blog.lazy-evaluation.net/posts/linux/debian-stretch-arm64.html

set -e

# CHROOT Directory
CHROOT_DIR=/tmp/chroot

# Debian package dependencies for the host to run ARM under QEMU
DEBIAN_MIRROR="http://ftp.debian.org/debian"
HOST_DEPENDENCIES="qemu-user-static binfmt-support debootstrap sbuild wget"

# Debian package dependencies for the chrooted environment
GUEST_DEPENDENCIES="build-essential libcurl4-openssl-dev libsqlite3-dev libgnutls-openssl27"

function setup_arm32_chroot {
	# Update apt repository details
	sudo apt-get update
	# 32Bit Variables
	VERSION=jessie
	CHROOT_ARCH=armhf
	# Host dependencies
	sudo apt-get install -qq -y ${HOST_DEPENDENCIES}
	# Download LDC compiler
	wget https://github.com/ldc-developers/ldc/releases/download/v1.10.0/ldc2-1.10.0-linux-armhf.tar.xz
	tar -xf ldc2-1.10.0-linux-armhf.tar.xz
	mv ldc2-1.10.0-linux-armhf dlang-${ARCH}
	rm -rf ldc2-1.10.0-linux-armhf.tar.xz
	# Create chrooted environment
	sudo mkdir ${CHROOT_DIR}
	sudo debootstrap --foreign --no-check-gpg --variant=buildd --arch=${CHROOT_ARCH} ${VERSION} ${CHROOT_DIR} ${DEBIAN_MIRROR}
	sudo cp /usr/bin/qemu-arm-static ${CHROOT_DIR}/usr/bin/
	sudo chroot ${CHROOT_DIR} /debootstrap/debootstrap --second-stage
	sudo sbuild-createchroot --arch=${CHROOT_ARCH} --foreign --setup-only ${VERSION} ${CHROOT_DIR} ${DEBIAN_MIRROR}
	configure_chroot
}

function setup_arm64_chroot {
	# Update apt repository details
	sudo apt-get update
	# 64Bit Variables
	VERSION64=stretch
	CHROOT_ARCH64=arm64
	# Host dependencies
	sudo apt-get install -qq -y ${HOST_DEPENDENCIES}
	# Download LDC compiler
	wget https://github.com/ldc-developers/ldc/releases/download/v1.10.0/ldc2-1.10.0-linux-armhf.tar.xz
	tar -xf ldc2-1.10.0-linux-armhf.tar.xz
	mv ldc2-1.10.0-linux-armhf dlang-${ARCH}
	rm -rf ldc2-1.10.0-linux-armhf.tar.xz
	# Create chrooted environment
	sudo mkdir ${CHROOT_DIR}
	sudo qemu-debootstrap --arch=${CHROOT_ARCH64} ${VERSION64} ${CHROOT_DIR} ${DEBIAN_MIRROR}
	configure_chroot
}

function setup_x32_chroot {
	# Update apt repository details
	sudo apt-get update
	# 32Bit Variables
	VERSION=jessie
	CHROOT_ARCH32=i386
	# Host dependencies
	sudo apt-get install -qq -y ${HOST_DEPENDENCIES}
	# Download DMD compiler
	wget http://downloads.dlang.org/releases/2.x/2.081.1/dmd.2.081.1.linux.tar.xz
	tar -xf dmd.2.081.1.linux.tar.xz
	mv dmd2 dlang-${ARCH}
	rm -rf dmd.2.081.1.linux.tar.xz
	# Create chrooted environment
	sudo mkdir ${CHROOT_DIR}
	sudo debootstrap --foreign --no-check-gpg --variant=buildd --arch=${CHROOT_ARCH32} ${VERSION} ${CHROOT_DIR} ${DEBIAN_MIRROR}
	sudo cp /usr/bin/qemu-i386-static ${CHROOT_DIR}/usr/bin/
	sudo cp /usr/bin/qemu-x86_64-static ${CHROOT_DIR}/usr/bin/
	sudo chroot ${CHROOT_DIR} /debootstrap/debootstrap --second-stage
	sudo sbuild-createchroot --arch=${CHROOT_ARCH32} --foreign --setup-only ${VERSION} ${CHROOT_DIR} ${DEBIAN_MIRROR}
	configure_chroot
}

function configure_chroot {
	# Create file with environment variables which will be used inside chrooted environment
	echo "export ARCH=${ARCH}" > envvars.sh
	echo "export TRAVIS_BUILD_DIR=${TRAVIS_BUILD_DIR}" >> envvars.sh
	chmod a+x envvars.sh
	
	# Install dependencies inside chroot
	sudo chroot ${CHROOT_DIR} apt-get update
	sudo chroot ${CHROOT_DIR} apt-get --allow-unauthenticated install -qq -y ${GUEST_DEPENDENCIES}
	
	# Create build dir and copy travis build files to our chroot environment
	sudo mkdir -p ${CHROOT_DIR}/${TRAVIS_BUILD_DIR}
	sudo rsync -a ${TRAVIS_BUILD_DIR}/ ${CHROOT_DIR}/${TRAVIS_BUILD_DIR}/

	# Indicate chroot environment has been set up
	sudo touch ${CHROOT_DIR}/.chroot_is_done

	# Call ourselves again which will cause tests to run
	sudo chroot ${CHROOT_DIR} bash -c "cd ${TRAVIS_BUILD_DIR} && chmod a+x ./.travis-ci.sh"
	sudo chroot ${CHROOT_DIR} bash -c "cd ${TRAVIS_BUILD_DIR} && ./.travis-ci.sh"
}

function build_onedrive {
	# Depending on architecture, build onedrive using applicable tool
	echo `uname -a`
	HOMEDIR=`pwd`
	if [ "${ARCH}" = "x64" ]; then
		# Build on x86_64 as normal
		make clean; make;
	else
		if [ "${ARCH}" = "x32" ]; then
			# 32Bit DMD Build
			make clean;
			make DC=${HOMEDIR}/dlang-${ARCH}/linux/bin32/dmd
		else
			# LDC Build - ARM32, ARM64
			make clean;
			make DC=${HOMEDIR}/dlang-${ARCH}/bin/ldmd2
		fi
	fi
	# Functional testing of built application
	test_onedrive
}

function test_onedrive {
	# Testing onedrive client
	./onedrive --version
}

if [ "${ARCH}" = "arm32" ] || [ "${ARCH}" = "arm64" ] || [ "${ARCH}" = "x32" ]; then
	if [ -e "/.chroot_is_done" ]; then
		# We are inside ARM chroot
		echo "Running inside chrooted QEMU ${ARCH} environment"
		. ./envvars.sh
		export PATH="$PATH:/usr/sbin:/sbin:/bin"
		build_onedrive
	else
		# Need to set up chrooted environment first
		echo "Setting up chrooted ${ARCH} build environment"
		if [ "${ARCH}" = "x32" ]; then
			# 32Bit i386 Environment
			setup_x32_chroot
		else
			if [ "${ARCH}" = "arm32" ]; then
				# 32Bit ARM Environment
				setup_arm32_chroot
			else
				# 64Bit ARM Environment
				setup_arm64_chroot
			fi
		fi
	fi
else
	# Proceed as normal
	echo "Running an x86_64 Build"
	build_onedrive
fi
