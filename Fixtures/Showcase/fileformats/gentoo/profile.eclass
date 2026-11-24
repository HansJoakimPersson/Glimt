# Shared Gentoo package helper
inherit toolchain-funcs

profile_configure() {
	local mode="${1:-default}"
	econf --with-mode="${mode}"
}
