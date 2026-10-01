# systemd stops and removes the previous bundle before starting a new one.
set -euo pipefail

package=${1:?usage: install-flclashx PACKAGE_OR_--remove OPT_DIRECTORY}
optRoot=${2:?usage: install-flclashx PACKAGE_OR_--remove OPT_DIRECTORY}
current="$optRoot/FlClashX"

fail() { echo "install-flclashx: $*" >&2; exit 1; }
secure_directory() {
  [[ -d $1 && ! -L $1 && $(stat -c %u "$1") == 0 ]] || fail "directory must belong to root: $1"
  local mode
  mode=$(stat -c %a "$1")
  (( (8#$mode & 0022) == 0 )) || fail "directory must not be group/world writable: $1"
}

[[ $EUID == 0 ]] || fail "run as root"
if [[ $package == --remove && ! -e $optRoot && ! -L $optRoot ]]; then exit 0; fi
[[ ! -L $optRoot ]] || fail "refusing symlink: $optRoot"
if [[ ! -e $optRoot ]]; then install -d -m 0755 -o root -g root "$optRoot"; fi
secure_directory "$optRoot"
[[ ! -L $current ]] || fail "refusing symlink: $current; stop the previous installation service first"

if [[ -e $current ]]; then
  secure_directory "$current"
  [[ -f $current/.nix-package ]] || fail "refusing unmanaged directory: $current"
  if [[ $package == --remove ]]; then rm -rf -- "$current"; exit 0; fi
  [[ $(cat "$current/.nix-package") == "$package" &&
     $(stat -c '%u:%g:%a' "$current/FlClashCore") == 0:0:4755 ]] || fail "stop the installation service before replacing its bundle"
  exit 0
fi
if [[ $package == --remove ]]; then exit 0; fi

bundle="$package/share/flclashx"
[[ -x $bundle/FlClashX && ! -L $bundle/FlClashX ]] || fail "missing GUI ELF"
[[ -x $bundle/FlClashCore && ! -L $bundle/FlClashCore ]] || fail "missing core ELF"

# Prepare privately; a failed copy must not leave a partially installed core.
stage=$(mktemp -d "$optRoot/.FlClashX.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
cp -a --no-preserve=ownership "$bundle/." "$stage/"
chown -R root:root "$stage"
chmod -R u+rwX,go-w "$stage"
chmod 0755 "$stage/FlClashX"
chmod 4755 "$stage/FlClashCore"
printf '%s\n' "$package" > "$stage/.nix-package"
chmod 0755 "$stage"
mv -T -- "$stage" "$current"
echo "FlClashX installed in $current"
