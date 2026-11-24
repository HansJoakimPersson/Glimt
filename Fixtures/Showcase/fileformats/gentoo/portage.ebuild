# Copyright 2026 Glimt
EAPI=8
DESCRIPTION="Example package metadata"
SLOT="0"
KEYWORDS="~amd64"

src_configure() {
	if use examples; then
		econf --enable-examples
	fi
}
