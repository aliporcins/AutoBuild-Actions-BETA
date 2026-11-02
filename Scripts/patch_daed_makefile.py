#!/usr/bin/env python3
"""Fork-local fail-fast patch for QiuSimons daed Makefile Build/Prepare.

Why: Prepare is a ';'-chained subshell, so a failed node download,
pnpm install, pnpm build or cp is silently swallowed and Prepare still
" succeeds", leaving webrender/web empty until the Go build fails hours
later with 'pattern web: cannot embed directory web'.
This patch makes Prepare abort loudly (set -e) and adds an explicit
non-empty guard on webrender/web before the build proceeds.

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
    s = s.replace(
        head,
        head + "\t\tset -e ; \\\n",
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
