#!/usr/bin/env python3
"""Fork-local fail-fast patch for QiuSimons daed Makefile Build/Prepare.

Why (part 1): Prepare is a ';'-chained subshell, so a failed node download,
pnpm install, pnpm build or cp is silently swallowed and Prepare still
"succeeds", leaving webrender/web empty until the Go build fails hours
later with 'pattern web: cannot embed directory web'.
This patch makes Prepare abort loudly (set -e) and adds an explicit
non-empty guard on webrender/web before the build proceeds.

Why (part 2, run 5): Prepare runs bare `go get -u=patch; go mod tidy`
against the system PATH, but the GitHub runner has no system Go at all
(run 4 died with `go: command not found`, Error 127, before node/pnpm
ever ran). The Go that compile uses comes from OpenWrt's hostpkg
(golang/host is in PKG_BUILD_DEPENDS, so it is built before daed's
Prepare). This patch therefore prepends the hostpkg Go bin dir to PATH
at the top of Prepare, before any `go` invocation.

Escaping note (proven by run 4's log line 20518): the Prepare body goes
through TWO make expansions before the shell sees it, so shell variables
in injected text must be written with FOUR dollars in this file
(e.g. the upstream `$$$$PATH` executes as `$PATH`). Make variables
($(STAGING_DIR_HOSTPKG), $(TOPDIR)) stay single-dollar.

Usage: patch_daed_makefile.py <path/to/package/daed/Makefile>
Exits nonzero (and changes nothing) if the anchor lines are not found
exactly once each -- so a future upstream Makefile change fails fast
at diy time instead of silently skipping the patch.
"""
import sys


def main():
    path = sys.argv[1]
    s = open(path).read()
    head = "define Build/Prepare\n\t( \\\n"
    assert s.count(head) == 1, f"prepare head anchor count = {s.count(head)}"
    # Go bin lookup order: (1) STAGING_DIR_HOSTPKG glob, (2) TOPDIR glob,
    # (3) the go-1.26 path observed in run 3's compile log. An undefined
    # STAGING_DIR_HOSTPKG expands to empty and its glob simply matches
    # nothing, so the loop falls through to the next candidate. If no
    # candidate provides an executable go, fail loudly instead of dying
    # later at the first `go get` with a bare "command not found".
    go_path = (
        "\t\tfor _d in $(STAGING_DIR_HOSTPKG)/lib/go-*/bin $(TOPDIR)/staging_dir/hostpkg/lib/go-*/bin $(TOPDIR)/staging_dir/hostpkg/lib/go-1.26/bin ; do if [ -x \"$$$${_d}/go\" ] ; then export PATH=\"$$$${_d}:$$$$PATH\" ; break ; fi ; done ; \\\n"
        "\t\tcommand -v go >/dev/null 2>&1 || { echo \"ERROR: no hostpkg Go found for daed Prepare\" ; exit 1 ; } ; \\\n"
    )
    s = s.replace(
        head,
        head + "\t\tset -e ; \\\n" + go_path,
        1,
    )
    tail = "\t\trm -rf $(DAED_BUILD_DIR)/.node_tmp ; \\\n"
    assert s.count(tail) == 1, f"prepare tail anchor count = {s.count(tail)}"
    guard = (
        "\t\tfind $(PKG_BUILD_DIR)/webrender/web -type f | grep -q . "
        '|| { echo "ERROR: daed web frontend build produced empty '
        "webrender/web; pnpm build likely failed, see above\"; exit 1; } ; \\\n"
    )
    s = s.replace(tail, guard + tail, 1)
    open(path, "w").write(s)
    print("daed Makefile fail-fast patch applied")


if __name__ == "__main__":
    main()
