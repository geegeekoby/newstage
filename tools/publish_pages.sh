#!/bin/sh
# 4.5.795: disabled. It cloned with the token in the URL, ran rsync --delete and
# committed a fixed message, all against the publish rules. Publish with
# tools/make_repo.py, copy to docs/, and a normal git push.
echo "publish_pages.sh is disabled (4.5.795)" >&2
exit 1
