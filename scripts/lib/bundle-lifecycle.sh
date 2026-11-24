# shellcheck shell=bash
# Glimt bundle lifecycle: scoped build locations and a controlled /Applications install.
#
# Sourced by the build, smoke and install scripts. Bash 3.2 compatible.
#
# Every Xcode build registers its products with LaunchServices at their DerivedData path
# (the RegisterWithLaunchServices step), and deleting a bundle never removes its records. So:
#   - builds go to a stable, locked scope directory, $GLIMT_SCOPE_ROOT/<name>/DerivedData;
#   - before a scope is deleted, every bundle Xcode recorded as registered and every .app inside
#     the scope is unregistered (`pluginkit -r` per extension, then `lsregister -u`);
#   - an install never keeps a copy in /Applications: the previous app is unregistered and moved
#     to the scope's rollback folder, and is unregistered and deleted again on commit.
# Only per-path operations are used. Nothing here resets LaunchServices, PlugInKit or Background
# Task Management. `lsregister` is an undocumented tool; `pluginkit` is the documented PlugInKit CLI.
#
# Privileged moves into /Applications go through the caller's optional SUDO array.

GLIMT_LIBRARY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GLIMT_SCOPE_ROOT="${GLIMT_SCOPE_ROOT:-$GLIMT_LIBRARY_ROOT/build/scoped.noindex}"
GLIMT_LSREGISTER="${GLIMT_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
GLIMT_PLUGINKIT="${GLIMT_PLUGINKIT:-pluginkit}"
GLIMT_APP_IDENTIFIER="com.glimt.app"
GLIMT_SCOPE_NAME=""
GLIMT_SCOPE_DIR=""
GLIMT_INSTALLED_APP=""
GLIMT_ROLLBACK_APP=""
GLIMT_INSTALL_PENDING=0

glimt_validate_scope_root() {
  local requested="$GLIMT_SCOPE_ROOT" resolved default_root default_parent requested_parent temp_root
  [[ "$requested" == /* ]] || { echo "error: build scope root must be absolute" >&2; return 1; }
  [[ "${requested##*/}" == "scoped.noindex" ]] || {
    echo "error: build scope root must end in scoped.noindex" >&2
    return 1
  }
  [[ ! -L "$requested" ]] || { echo "error: build scope root must not be a symlink" >&2; return 1; }
  default_parent="$(cd -P "$GLIMT_LIBRARY_ROOT" && pwd)/build"
  default_root="$default_parent/scoped.noindex"
  if [[ "$requested" == "$default_root" || "$requested" == "$GLIMT_LIBRARY_ROOT/build/scoped.noindex" ]]; then
    [[ ! -L "$default_parent" ]] || { echo "error: project build directory must not be a symlink" >&2; return 1; }
    mkdir -p "$default_parent" || return 1
    requested_parent="$(cd -P "$default_parent" && pwd)" || return 1
    [[ "$requested_parent" == "$default_parent" ]] || {
      echo "error: project build directory resolves outside the repository" >&2
      return 1
    }
  else
    requested_parent="${requested%/*}"
    [[ -d "$requested_parent" ]] || {
      echo "error: custom build scope parent must already exist" >&2
      return 1
    }
    requested_parent="$(cd -P "$requested_parent" && pwd)" || return 1
    if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
      temp_root="$(cd -P "$TMPDIR" && pwd)" || return 1
      [[ "$requested_parent" == "$temp_root" || "$requested_parent" == "$temp_root"/* ]] && {
        mkdir -p "$requested" || return 1
        resolved="$(cd -P "$requested" && pwd)" || return 1
        [[ "$resolved" == "$requested_parent/scoped.noindex" ]] && return 0
      }
    fi
    temp_root="$(cd -P /private/tmp 2>/dev/null && pwd)" || temp_root=""
    if [[ -n "$temp_root" && ( "$requested_parent" == "$temp_root" || "$requested_parent" == "$temp_root"/* ) ]]; then
      mkdir -p "$requested" || return 1
      resolved="$(cd -P "$requested" && pwd)" || return 1
      [[ "$resolved" == "$requested_parent/scoped.noindex" ]] && return 0
    fi
    echo "error: custom build scope root is allowed only below the system temporary directory" >&2
    return 1
  fi
  mkdir -p "$requested" || { echo "error: could not create build scope root" >&2; return 1; }
  resolved="$(cd -P "$requested" && pwd)" || return 1
  [[ "$resolved" == "$default_root" ]] || {
    echo "error: build scope root resolves outside the repository" >&2
    return 1
  }
}

glimt_privileged() {
  ${SUDO[@]+"${SUDO[@]}"} "$@"
}

# MARK: Registration

# Removes one bundle's LaunchServices and PlugInKit records. Works whether or not the bundle still
# exists, but must run before the bundle is deleted so its extensions can be named.
glimt_unregister_bundle() {
  local app="$1" extension output
  for extension in "$app"/Contents/PlugIns/*.appex; do
    [[ -d "$extension" ]] || continue
    # Already unregistered is the goal state, so an interrupted cleanup can be retried:
    # pluginkit reports "no plugin at", lsregister kLSApplicationNotFoundErr (-10814).
    output="$("$GLIMT_PLUGINKIT" -r "$extension" 2>&1)" || [[ "$output" == *"no plugin at"* ]] || {
      echo "error: could not unregister extension at $extension" >&2
      return 1
    }
  done
  output="$("$GLIMT_LSREGISTER" -u "$app" 2>&1)" || [[ "$output" == *": -10814"* ]] || {
    echo "error: could not unregister bundle at $app" >&2
    return 1
  }
}

glimt_register_installed() {
  local app="$1" extension
  "$GLIMT_LSREGISTER" -f -R -trusted "$app"
  for extension in "$app"/Contents/PlugIns/*.appex; do
    [[ -d "$extension" ]] || continue
    "$GLIMT_PLUGINKIT" -a "$extension"
  done
}

# Terminates processes whose command line starts inside <prefix>, never this shell.
glimt_quit_processes() {
  local prefix="$1" pids pid _
  pids="$(pgrep -f "$prefix" 2>/dev/null | grep -vx "$$" || true)"
  [[ -n "$pids" ]] || return 0
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pids="$(pgrep -f "$prefix" 2>/dev/null | grep -vx "$$" || true)"
    [[ -n "$pids" ]] || return 0
    sleep 0.5
  done
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
}

# Terminates the app and its extension processes running from inside a bundle.
glimt_quit_bundle_processes() {
  glimt_quit_processes "$1/Contents/"
}

# MARK: Scoped build locations

# Unregisters every bundle in the scope (except a rollback copy) and everything Xcode recorded as
# registered by a build there, then deletes the scope's contents.
glimt_release_scope_contents() {
  local dir="$1" record app
  [[ -d "$dir" ]] || return 0
  {
    record="$dir/DerivedData/Build/Intermediates.noindex/XCBuildData/registered-launchservices.txt"
    if [[ -f "$record" ]]; then cat "$record"; fi
    find "$dir" -path "$dir/rollback" -prune -o -name '*.app' -type d -print -prune
  } | awk 'NF && !seen[$0]++' | while IFS= read -r app; do
    glimt_unregister_bundle "$app" || exit 1
  done || return 1
  rm -rf "$dir/DerivedData" "$dir/staging"
  if [[ -d "$dir/rollback" ]] && find "$dir/rollback" -mindepth 1 -print -quit | grep -q .; then
    echo "error: rollback data remains in build scope $dir" >&2
    return 1
  fi
  rmdir "$dir/rollback" 2>/dev/null || true
  rmdir "$dir" 2>/dev/null || true
}

# Claims the stable scope <name>: one owner at a time, a dead owner's leftovers released first.
# Set GLIMT_INSTALL_DESTINATION before claiming an install scope so an interrupted install's
# rollback copy can be restored.
glimt_claim_scope() {
  local name="$1" lock owner
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "error: invalid build scope name" >&2
    return 1
  }
  glimt_validate_scope_root || return 1
  lock="$GLIMT_SCOPE_ROOT/$name.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ps -p "$owner" >/dev/null 2>&1; then
      echo "error: build scope $name is in use by process $owner" >&2
      return 1
    fi
    rm -rf "$lock"
    mkdir "$lock"
  fi
  echo "$$" > "$lock/pid"
  GLIMT_SCOPE_NAME="$name"
  GLIMT_SCOPE_DIR="$GLIMT_SCOPE_ROOT/$name"
  if [[ -d "$GLIMT_SCOPE_DIR/rollback/Glimt.app" ]]; then
    local destination="${GLIMT_INSTALL_DESTINATION:-}"
    if [[ -z "$destination" || -e "$destination" ]]; then
      echo "error: $GLIMT_SCOPE_DIR/rollback/Glimt.app is the rollback copy of an interrupted install." >&2
      echo "Keep it by moving it back over ${destination:-the installed app}, or delete it once that install is verified." >&2
      rm -rf "$lock"
      GLIMT_SCOPE_NAME=""; GLIMT_SCOPE_DIR=""
      return 1
    fi
    echo "Restoring the previous app left by an interrupted install"
    glimt_privileged mv "$GLIMT_SCOPE_DIR/rollback/Glimt.app" "$destination"
    glimt_register_installed "$destination"
  fi
  glimt_release_scope_contents "$GLIMT_SCOPE_DIR"
  mkdir -p "$GLIMT_SCOPE_DIR"
}

glimt_release_scope() {
  [[ -n "$GLIMT_SCOPE_NAME" ]] || return 0
  if ! glimt_release_scope_contents "$GLIMT_SCOPE_DIR"; then
    echo "error: build scope cleanup did not complete; its lock was retained" >&2
    return 1
  fi
  rm -rf "$GLIMT_SCOPE_ROOT/$GLIMT_SCOPE_NAME.lock"
  GLIMT_SCOPE_NAME=""
}

# MARK: Install

glimt_bundle_identifier() {
  [[ -f "$1/Contents/Info.plist" ]] || return 0
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Installs <candidate> at <destination> inside the claimed scope. The previous app is unregistered
# and kept outside /Applications until glimt_commit_install or glimt_rollback_install.
glimt_install_app() {
  local candidate="$1" destination="$2" identifier staging
  [[ -n "$GLIMT_SCOPE_NAME" ]] || { echo "error: claim a scope before installing" >&2; return 1; }
  [[ -d "$candidate/Contents" ]] || { echo "error: $candidate is not an app bundle" >&2; return 1; }
  if [[ -e "$destination" ]]; then
    identifier="$(glimt_bundle_identifier "$destination")"
    if [[ -n "$identifier" && "$identifier" != "$GLIMT_APP_IDENTIFIER" ]]; then
      echo "error: $destination belongs to $identifier; refusing to replace it" >&2
      return 1
    fi
    if pgrep -f "$destination/Contents/MacOS/" >/dev/null 2>&1; then
      echo "error: $destination is running; quit it before installing" >&2
      return 1
    fi
  fi
  staging="$GLIMT_SCOPE_DIR/staging"
  rm -rf "$staging"
  mkdir -p "$staging"
  ditto "$candidate" "$staging/Glimt.app"
  GLIMT_INSTALLED_APP="$destination"
  if [[ -e "$destination" ]]; then
    glimt_quit_bundle_processes "$destination"
    glimt_unregister_bundle "$destination"
    mkdir -p "$GLIMT_SCOPE_DIR/rollback"
    glimt_privileged mv "$destination" "$GLIMT_SCOPE_DIR/rollback/Glimt.app"
    GLIMT_ROLLBACK_APP="$GLIMT_SCOPE_DIR/rollback/Glimt.app"
    GLIMT_INSTALL_PENDING=1
  fi
  glimt_privileged mv "$staging/Glimt.app" "$destination"
  GLIMT_INSTALL_PENDING=1
  rmdir "$staging"
  glimt_register_installed "$destination"
}

# Keeps the verified install and deletes the previous app (already unregistered when moved aside).
glimt_commit_install() {
  if [[ -n "$GLIMT_ROLLBACK_APP" ]]; then
    if ! glimt_unregister_bundle "$GLIMT_ROLLBACK_APP"; then
      echo "error: previous app remains in rollback because it could not be unregistered" >&2
      return 1
    fi
    glimt_privileged rm -rf "$GLIMT_ROLLBACK_APP" || return 1
    rmdir "$GLIMT_SCOPE_DIR/rollback" 2>/dev/null || true
  fi
  GLIMT_ROLLBACK_APP=""
  GLIMT_INSTALL_PENDING=0
}

# Quits, unregisters and removes the new install, then restores and re-registers the previous app.
glimt_rollback_install() {
  [[ "$GLIMT_INSTALL_PENDING" == 1 ]] || return 0
  local destination="$GLIMT_INSTALLED_APP"
  if [[ -e "$destination" && ( -z "$GLIMT_ROLLBACK_APP" || -e "$GLIMT_ROLLBACK_APP" ) ]]; then
    glimt_quit_bundle_processes "$destination"
    if ! glimt_unregister_bundle "$destination"; then
      echo "error: installed app remains because it could not be unregistered" >&2
      return 1
    fi
    glimt_privileged rm -rf "$destination" || return 1
  fi
  if [[ -n "$GLIMT_ROLLBACK_APP" && -e "$GLIMT_ROLLBACK_APP" && ! -e "$destination" ]]; then
    glimt_privileged mv "$GLIMT_ROLLBACK_APP" "$destination"
    rmdir "$GLIMT_SCOPE_DIR/rollback" 2>/dev/null || true
    glimt_register_installed "$destination"
    echo "Rolled back to the previous $destination" >&2
  fi
  GLIMT_ROLLBACK_APP=""
  GLIMT_INSTALL_PENDING=0
}

# MARK: Traps

# Use from an EXIT trap: rolls back an uncommitted install and releases the scope.
glimt_finish() {
  local status=$?
  set +e
  glimt_rollback_install || status=1
  glimt_release_scope || status=1
  return $status
}

# Makes INT, TERM and HUP exit through the EXIT trap so cleanup always runs.
glimt_exit_on_signals() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}
