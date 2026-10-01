# Used by the NixOS installation service; only FlClashCore is setuid.
set -euo pipefail

package=${1:?usage: install-flclashx PACKAGE_OR_--remove OPT_DIRECTORY}
optRoot=${2:?usage: install-flclashx PACKAGE OPT_DIRECTORY}
versions="$optRoot/FlClashX-versions"
current="$optRoot/FlClashX"

fail() {
  echo "install-flclashx: $*" >&2
  exit 1
}

[[ $EUID == 0 ]] || fail "run as root"

if [[ $package != --remove ]]; then
  bundle="$package/share/flclashx"
  name=$(basename "$package")
  target="$versions/$name"
  [[ $name =~ ^[a-z0-9]{32}-flclashx-[0-9][a-zA-Z0-9.+_-]*$ ]] || fail "unexpected package name: $name"
  [[ -x $bundle/FlClashX && ! -L $bundle/FlClashX ]] || fail "missing GUI ELF"
  [[ -x $bundle/FlClashCore && ! -L $bundle/FlClashCore ]] || fail "missing core ELF"
elif [[ ! -e $versions && ! -L $versions ]]; then
  exit 0
fi

# Never put a privileged core in a directory writable by another user.
for directory in "$optRoot" "$versions"; do
  [[ ! -L $directory ]] || fail "refusing symlink: $directory"
  if [[ ! -e $directory ]]; then
    install -d -m 0755 -o root -g root "$directory"
  fi
  [[ -d $directory && $(stat -c %u "$directory") == 0 ]] || fail "directory must belong to root: $directory"
  mode=$(stat -c %a "$directory")
  (( (8#$mode & 0022) == 0 )) || fail "directory must not be group/world writable: $directory"
done
[[ ! -e $current || -L $current ]] || fail "$current already exists as a real directory; move it aside first"

exec 9>"$versions/.install.lock"
flock 9

remove_old_versions() {
  local old
  while IFS= read -r -d '' old; do
    if [[ $old != "$1" && -f $old/.nix-package ]]; then
      chmod u-s "$old/FlClashCore"
      rm -rf -- "$old"
    fi
  done < <(find "$versions" -mindepth 1 -maxdepth 1 -type d -name '*-flclashx-*' -print0)
}

if [[ $package == --remove ]]; then
  if [[ -L $current ]]; then
    case $(readlink "$current") in
      "$versions/"*) rm -- "$current" ;;
      *) fail "refusing to remove an unmanaged symlink: $current" ;;
    esac
  fi
  remove_old_versions ""
  exit 0
fi

# Rebuilds of the same package should not disturb a running instance.
if [[ -L $current && $(readlink "$current") == "$target" &&
      -f $target/.nix-package && $(cat "$target/.nix-package") == "$package" &&
      $(stat -c '%u:%g:%a' "$target/FlClashCore") == 0:0:4755 ]]; then
  exit 0
fi
stage=$(mktemp -d "$versions/.stage.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
if [[ -e $target || -L $target ]]; then
  # Recover if activation stopped after copying but before switching the link.
  [[ ! -L $target && -f $target/.nix-package &&
     $(cat "$target/.nix-package") == "$package" &&
     $(stat -c '%u:%g:%a' "$target/FlClashCore") == 0:0:4755 ]] || fail "unexpected existing installation: $target"
else
  cp -a --no-preserve=ownership "$bundle/." "$stage/"
  chown -R root:root "$stage"
  chmod -R u+rwX,go-w "$stage"
  chmod 0755 "$stage" "$stage/FlClashX"
  chmod 4755 "$stage/FlClashCore"
  printf '%s\n' "$package" > "$stage/.nix-package"
  mv -T -- "$stage" "$target"
  stage=$(mktemp -d "$versions/.stage.XXXXXXXX")
fi

# Atomically replace the public symlink only after the copy is complete.
ln -s "$target" "$stage/current"
mv -Tf -- "$stage/current" "$current"

# Rebuilding an old generation recreates its copy from the retained Nix bundle.
# Do not leave obsolete setuid binaries behind after an update.
remove_old_versions "$target"
echo "FlClashX installed in $current"
