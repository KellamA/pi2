#!/bin/bash
# Makes the three sample git repositories the README's pictures are staged on, afresh, in a folder of your choice:
# <folder>/storefront, <folder>/docs-site and <folder>/mobile-app, from the plain files in samples/. The folder's path
# shows in a project's hub, so choose one that reads neutrally, such as /Users/Shared/Projects.
#
#   scripts/readme-pictures/reset.sh <folder>          make them (again)
#   scripts/readme-pictures/reset.sh <folder> --remove remove them, and the folder if that leaves it empty
#
# It removes only repositories it made itself (each has .git/readme-pictures), and refuses to replace anything else.
set -euo pipefail
here=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
[[ $# -ge 1 && -n $1 ]] || { echo "usage: $0 <folder> [--remove]" >&2; exit 2; }
base=${1%/}
names=(storefront docs-site mobile-app)

for name in "${names[@]}"; do
	target="$base/$name"
	if [[ -e $target || -L $target ]]; then
		[[ -f $target/.git/readme-pictures && ! -L $target ]] || { echo "$target is there and was not made by this script; leaving it alone." >&2; exit 1; }
	fi
done
for name in "${names[@]}"; do rm -rf "${base:?}/$name"; done
if [[ ${2:-} == --remove ]]; then
	rmdir "$base" 2>/dev/null || true
	echo "Removed the sample repositories from $base."
	exit 0
fi

mkdir -p "$base"
git_() { git -c user.name=Sample -c user.email=sample@example.com -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }
for name in "${names[@]}"; do
	cp -R "$here/samples/$name" "$base/$name"
	(cd "$base/$name" && git_ init -q && touch .git/readme-pictures)
done

# The storefront's history has the change that caused its bug: the address form that keeps a Canadian province apart.
(
	cd "$base/storefront"
	address=src/checkout/address.ts
	grep -v -e 'province' -e 'A Canadian province' "$here/samples/storefront/$address" > "$address"
	git_ add -A && git_ commit -qm "Northwind storefront 2.4.0"
	cp "$here/samples/storefront/$address" "$address"
	git_ commit -qam "New address form: keep the Canadian province apart from the US state"
)
for name in docs-site mobile-app; do (cd "$base/$name" && git_ add -A && git_ commit -qm "First commit"); done
echo "Made storefront, docs-site and mobile-app in $base."
