#!/usr/bin/env bash
# Purge supported Firefox installations and the current user's Firefox data.
# Exit if a command fails, an unset variable is used, or a pipeline fails.
set -euo pipefail

# Use preview mode unless the user explicitly requests deletion.
mode="${1:---dry-run}"
# Accept only the documented command-line options.
case "$mode" in
  # Allow a read-only preview or an explicitly requested purge.
  --dry-run|--apply) ;;
  # Reject unfamiliar options instead of guessing their meaning.
  *) printf 'Usage: %s [--dry-run|--apply]\n' "$0" >&2; exit 2 ;;
# Finish checking the command-line argument.
esac

# Reject extra arguments so they cannot accidentally be ignored.
if (( $# > 1 )); then
  # Explain the supported invocation before exiting.
  printf 'Usage: %s [--dry-run|--apply]\n' "$0" >&2
  # Stop with a command-line error.
  exit 2
# Finish checking the number of arguments.
fi

# Never run the entire script as root: user data must belong to the caller.
if (( EUID == 0 )); then
  # Give a safe way to invoke the script.
  printf 'Run as your regular user, not with sudo.\n' >&2
  # Stop before examining or changing anything.
  exit 1
# Finish the root-user safety check.
fi

# Require an existing absolute home directory and the realpath utility.
if [[ ! -d "${HOME:-}" || "${HOME:-}" != /* ]] || ! command -v realpath >/dev/null 2>&1; then
  # Refuse to operate without a trustworthy home path.
  printf 'A valid HOME and the realpath utility are required.\n' >&2
  # Stop when basic path safety cannot be established.
  exit 1
# Finish validating the runtime environment.
fi

# Resolve HOME to a canonical path for later safety checks.
safe_home="$(realpath -- "$HOME")"
# Refuse a home directory that resolves to the filesystem root.
if [[ "$safe_home" == / ]]; then
  # Explain why this path is unsafe.
  printf 'Refusing to use / as HOME.\n' >&2
  # Stop before building deletion targets.
  exit 1
# Finish validating the canonical home directory.
fi

# Start with no detected distribution-package manager.
package_manager=""
# Choose APT only when its package database and installer are available.
if command -v dpkg-query >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  # Remember the APT package-manager family.
  package_manager="apt"
# Otherwise try the RPM database and DNF.
elif command -v rpm >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
  # Remember DNF as the package manager.
  package_manager="dnf"
# Otherwise try the RPM database and Zypper.
elif command -v rpm >/dev/null 2>&1 && command -v zypper >/dev/null 2>&1; then
  # Remember Zypper as the package manager.
  package_manager="zypper"
# Otherwise try Pacman and its package database.
elif command -v pacman >/dev/null 2>&1; then
  # Remember Pacman as the package manager.
  package_manager="pacman"
# Finish choosing among supported distribution-package managers.
fi

# Check whether one exact package name is installed.
package_installed() {
  # Select the package-database query appropriate to this system.
  case "$package_manager" in
    # Query Debian's installed-package status, ignoring missing package errors.
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fxq 'install ok installed' ;;
    # Check the RPM database without changing packages.
    dnf|zypper) rpm -q -- "$1" >/dev/null 2>&1 ;;
    # Check the Pacman database without changing packages.
    pacman) pacman -Q -- "$1" >/dev/null 2>&1 ;;
    # An unknown package manager cannot safely be handled automatically.
    *) return 1 ;;
  # Finish checking the appropriate package database.
  esac
# Finish the package-query function.
}

# Create an initially empty array of exact package names to remove.
packages=()
# Consider the normal Firefox and Firefox ESR distribution packages.
for package in firefox firefox-esr; do
  # Record only packages that are actually installed.
  if package_installed "$package"; then
    # Append the verified package name to the removal plan.
    packages+=("$package")
  # Finish checking this package.
  fi
# Finish checking distribution-installed Firefox packages.
done

# Assume no Flatpak Firefox installation until verified.
flatpak_user=false
# Assume no system-wide Flatpak Firefox installation until verified.
flatpak_system=false
# Look for Firefox under the calling user's Flatpak installation.
if command -v flatpak >/dev/null 2>&1 && flatpak info --user org.mozilla.firefox >/dev/null 2>&1; then
  # Record the user-scoped Flatpak installation.
  flatpak_user=true
# Finish checking user-scoped Flatpak.
fi
# Look for Firefox under the default system-wide Flatpak installation.
if command -v flatpak >/dev/null 2>&1 && flatpak info --system org.mozilla.firefox >/dev/null 2>&1; then
  # Record the system-scoped Flatpak installation.
  flatpak_system=true
# Finish checking system-scoped Flatpak.
fi

# Assume Snap Firefox is absent until checked.
snap_installed=false
# Ask Snap whether the exact Firefox application is installed.
if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
  # Record the system-wide Snap installation.
  snap_installed=true
# Finish checking Snap.
fi

# List only Firefox-specific paths; do not delete their shared parent folders.
data_candidates=(
  # Traditional Mozilla Firefox profile and related state.
  "$HOME/.mozilla/firefox"
  # Firefox configuration under the XDG configuration directory.
  "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
  # Firefox cache under the XDG cache directory.
  "${XDG_CACHE_HOME:-$HOME/.cache}/mozilla/firefox"
  # Firefox data under the XDG data directory, when used.
  "${XDG_DATA_HOME:-$HOME/.local/share}/mozilla/firefox"
  # The entire sandbox-specific Firefox Flatpak data directory.
  "$HOME/.var/app/org.mozilla.firefox"
  # The current user's Firefox Snap data directory.
  "$HOME/snap/firefox"
# Finish the list of known Firefox data locations.
)

# Start with an empty list of paths that actually exist.
data_paths=()
# Review every candidate before letting it into the deletion plan.
for path in "${data_candidates[@]}"; do
  # Skip missing paths but also recognize symbolic links, including dangling ones.
  if [[ -e "$path" || -L "$path" ]]; then
    # Resolve symbolic links and parent directories to their real location.
    resolved="$(realpath -m -- "$path")"
    # Refuse any target that resolves outside the current user's home.
    if [[ "$resolved" != "$safe_home/"* ]]; then
      # Report the rejected path rather than deleting an unexpected location.
      printf 'Unsafe path (outside HOME): %s -> %s\n' "$path" "$resolved" >&2
      # Stop the entire operation if a target cannot be trusted.
      exit 1
    # Finish checking the target location.
    fi
    # Block deletion of any path that is itself a mount point.
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q -- "$path"; then
      # Explain why deleting the mounted tree would be dangerous.
      printf 'Refusing mounted path: %s\n' "$path" >&2
      # Stop instead of crossing a mounted filesystem.
      exit 1
    # Finish checking for a mounted target.
    fi
    # Add the verified path to the list that could be removed.
    data_paths+=("$path")
  # Finish checking this candidate.
  fi
# Finish building the verified data-removal list.
done

# Display the planned distribution-package actions.
printf 'Package manager: %s\n' "${package_manager:-unsupported or not found}"
# Show each distribution package separately for readability.
for package in "${packages[@]}"; do
  # Print a package that would be removed.
  printf '  Remove package: %s\n' "$package"
# Finish displaying distribution packages.
done
# Report whether each of the two Flatpak installations was found.
printf 'Firefox Flatpak (user): %s\nFirefox Flatpak (system): %s\n' "$flatpak_user" "$flatpak_system"
# Report whether a Firefox Snap was found.
printf 'Firefox Snap (system): %s\n' "$snap_installed"
# Display the exact paths targeted for deletion.
for path in "${data_paths[@]}"; do
  # Print the path without deleting or changing it.
  printf '  Delete data: %s\n' "$path"
# Finish displaying file and directory targets.
done
# Explain important limits of the detection logic.
printf '%s\n' 'Not covered: custom profile locations, portable installs, other users, backups, or Firefox Sync cloud data.'

# Stop here by default: the preview must never change the system.
if [[ "$mode" == --dry-run ]]; then
  # Explain how to request the destructive operation intentionally.
  printf '%s\n' 'Preview only. Use --apply to request deletion.'
  # Exit successfully without modifying files or packages.
  exit 0
# Finish the default no-changes mode.
fi

# Require an interactive terminal to prevent unattended deletion.
if [[ ! -t 0 ]]; then
  # Explain why confirmation cannot be collected.
  printf 'Interactive terminal required for --apply.\n' >&2
  # Stop if standard input is not a terminal.
  exit 1
# Finish checking for an interactive terminal.
fi

# Check the caller's process list for a still-running Firefox browser.
if command -v pgrep >/dev/null 2>&1 && pgrep -u "$(id -u)" -x 'firefox|firefox-bin|firefox-esr' >/dev/null; then
  # Ask the user to close Firefox so profile databases are not in use.
  printf 'Close Firefox completely before using --apply.\n' >&2
  # Stop before attempting removal.
  exit 1
# Finish checking for running Firefox processes.
fi

# Warn that no automatic backup is created and package managers may remove dependencies.
printf '%s\n' 'WARNING: No backup will be made. Package managers may propose removing additional packages.'
# Require the exact phrase before making any changes.
read -r -p 'Type PURGE FIREFOX to continue: ' confirmation
# Reject anything other than the full phrase.
if [[ "$confirmation" != 'PURGE FIREFOX' ]]; then
  # Confirm cancellation without touching the system.
  printf 'Cancelled.\n'
  # Exit successfully because cancellation was intentional.
  exit 0
# Finish checking the destructive-operation confirmation.
fi

# Require additional approval because Snap purge affects users beyond this account.
if [[ "$snap_installed" == true ]]; then
  # Explicitly warn about the system-wide effects of Snap purge.
  printf '%s\n' 'WARNING: Snap purge can remove Firefox data belonging to OTHER system users.'
  # Require a second confirmation specific to Snap's broad scope.
  read -r -p 'Type PURGE SNAP ALL USERS to continue: ' snap_confirmation
  # Refuse the entire operation if the extra approval is not given.
  if [[ "$snap_confirmation" != 'PURGE SNAP ALL USERS' ]]; then
    # Explain that nothing has been changed so far.
    printf 'Cancelled before any changes.\n'
    # Stop without modifying the system.
    exit 0
  # Finish checking the Snap-specific confirmation.
  fi
# Finish checking the presence of Snap Firefox.
fi

# Remove distribution packages only when at least one was identified.
if (( ${#packages[@]} > 0 )); then
  # Select the removal command matching the detected package manager.
  case "$package_manager" in
    # Purge Debian-family Firefox packages and their system configuration.
    apt) sudo apt-get purge "${packages[@]}" ;;
    # Remove RPM Firefox packages using DNF's dependency-aware transaction.
    dnf) sudo dnf remove "${packages[@]}" ;;
    # Remove RPM Firefox packages using Zypper.
    zypper) sudo zypper remove "${packages[@]}" ;;
    # Remove only named packages through Pacman without an orphan sweep.
    pacman) sudo pacman -R "${packages[@]}" ;;
  # Finish selecting the distribution-package removal command.
  esac
# Finish removing distribution packages.
fi

# Remove a user-installed Flatpak Firefox and its sandbox-specific data.
if [[ "$flatpak_user" == true ]]; then
  # Delete only this application from the user's Flatpak installation.
  flatpak uninstall --user --app --delete-data org.mozilla.firefox
# Finish handling user-scoped Flatpak Firefox.
fi
# Remove a system-installed Flatpak Firefox without targeting other users' data.
if [[ "$flatpak_system" == true ]]; then
  # Let Flatpak manage its own system-wide application files.
  flatpak uninstall --system --app org.mozilla.firefox
# Finish handling system-scoped Flatpak Firefox.
fi
# Remove the Snap and its managed data only after the special confirmation.
if [[ "$snap_installed" == true ]]; then
  # Prevent Snap from creating a new automatic removal snapshot.
  sudo snap remove --purge firefox
# Finish handling Snap Firefox.
fi

# Remove the calling user's known Firefox profiles and cached data.
for path in "${data_paths[@]}"; do
  # Recheck path resolution immediately before attempting deletion.
  resolved="$(realpath -m -- "$path")"
  # Abort if a path now points outside the user's home directory.
  if [[ "$resolved" != "$safe_home/"* ]]; then
    # Explain the rejected path and avoid deleting it.
    printf 'Path changed or became unsafe: %s\n' "$path" >&2
    # Stop before further deletion.
    exit 1
  # Finish checking the current resolved location.
  fi
  # Refuse to delete an exact mount point, including one mounted since preview.
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q -- "$path"; then
    # Report the mounted target without traversing its contents.
    printf 'Path is mounted; stopping: %s\n' "$path" >&2
    # Stop without removing this target.
    exit 1
  # Finish rechecking the mount-point condition.
  fi
  # Delete only this reviewed Firefox-specific path, not its parent.
  rm -rf -- "$path"
  # Report the completed removal of that path.
  printf 'Removed: %s\n' "$path"
# Finish removing known Firefox data directories.
done

# Print completion, while avoiding a guarantee of total forensic erasure.
printf '%s\n' 'Finished. Check for custom Firefox installs, custom profiles, and existing backups separately.'
