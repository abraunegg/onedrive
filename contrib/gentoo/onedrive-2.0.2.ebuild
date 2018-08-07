# Copyright 1999-2018 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2

EAPI=6

DESCRIPTION="Onedrive sync client for Linux"
HOMEPAGE="https://github.com/abraunegg/onedrive"
SRC_URI="https://github.com/abraunegg/onedrive/archive/v${PV}.tar.gz -> ${P}.tar.gz"

LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64 ~x86"
IUSE=""

DEPEND="
    || (  
        dev-util/dub[dmd-2_080]
        dev-util/dub[dmd-2_079]
        dev-util/dub[dmd-2_078]
        dev-util/dub[dmd-2_076]
        dev-util/dub[dmd-2_075]
        dev-util/dub[dmd-2_074]
)
	dev-db/sqlite
"

RDEPEND="${DEPEND}
	net-misc/curl
	"
src_prepare() {
	default
	# Update the makefile so that it doesnt use git commands to get the version during build.
	sed -i -e "s/version:.*/version:/" \
		-e "\$s/.*/\techo v${PV} > version/" \
		Makefile
}
