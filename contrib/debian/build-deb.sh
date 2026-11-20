#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)

for tool in dpkg-deb dpkg-shlibdeps dpkg-architecture make tar; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		printf 'Required packaging tool is missing: %s\n' "$tool" >&2
		exit 1
	fi
done

base_version=$(sed -n 's/^AC_INIT(\[onedrive\],\[v\([^]]*\)\].*/\1/p' "$source_dir/configure.ac" | sed -n '1p')
if [ -z "$base_version" ]; then
	printf 'Unable to read the application version from configure.ac\n' >&2
	exit 1
fi

package_version="${base_version}+local.$(date -u +%Y%m%d%H%M%S)"
application_version="v${package_version}"
architecture=$(dpkg-architecture -qDEB_HOST_ARCH)
build_root=$(mktemp -d "${TMPDIR:-/tmp}/onedrive-deb.XXXXXX")
trap 'rm -rf "$build_root"' 0
trap 'exit 1' HUP INT TERM

build_source="$build_root/source"
package_root="$build_source/debian/onedrive"
mkdir -p "$build_source" "$build_source/debian" "$package_root/DEBIAN"

# Build from a snapshot so packaging does not alter the developer's checkout.
tar -C "$source_dir" \
	--exclude=.git \
	--exclude=onedrive \
	--exclude=onedrive.o \
	--exclude=version \
	--exclude=onedrive.1 \
	--exclude='onedrive_*.deb' \
	--exclude=config.log \
	--exclude=config.status \
	--exclude=autom4te.cache \
	-cf - . | tar -C "$build_source" -xf -

(
	cd "$build_source"
	./configure --prefix=/usr --sysconfdir=/etc DC="${DC:-ldc2}"
	make clean
	make version="$application_version"
	make DESTDIR="$package_root" version="$application_version" install
	make DESTDIR="$package_root" version="$application_version" install-cinnamon-applet
)

cat > "$build_source/debian/control" <<EOF
Source: onedrive
Section: net
Priority: optional
Maintainer: Local build <local@localhost>
Build-Depends: dpkg-dev
Standards-Version: 4.6.2

Package: onedrive
Architecture: any
Description: OneDrive Client for Linux
 A local package built from the current source tree.
EOF

binary_path="$package_root/usr/bin/onedrive"
dependency_output=$(cd "$build_source" && dpkg-shlibdeps -O -e "$binary_path")
runtime_dependencies=$(printf '%s\n' "$dependency_output" | sed -n 's/^shlibs:Depends=//p')
if [ -z "$runtime_dependencies" ]; then
	printf 'Unable to determine the runtime library dependencies for the package\n' >&2
	exit 1
fi

cat > "$package_root/DEBIAN/control" <<EOF
Package: onedrive
Version: $package_version
Section: net
Priority: optional
Architecture: $architecture
Maintainer: Local build <local@localhost>
Depends: $runtime_dependencies, systemd
Description: OneDrive Client for Linux
 A local package built from the current source tree.
 Includes the optional Cinnamon status applet.
EOF

output_path="$source_dir/onedrive_${package_version}_${architecture}.deb"
dpkg-deb --build --root-owner-group "$package_root" "$output_path"
printf 'Created package: %s\n' "$output_path"
