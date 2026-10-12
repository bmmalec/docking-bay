BASE="$1"
[ -d "$BASE" ] || { echo "no such directory: $BASE" >&2; exit 3; }
for d in "$BASE"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  [ "$name" = "lost+found" ] && continue
  dcfile="${d}.devcontainer/devcontainer.json"
  hasdc=0
  wsfolder=""
  if [ -f "$dcfile" ]; then
    hasdc=1
    wsfolder="$(grep -o '"workspaceFolder"[[:space:]]*:[[:space:]]*"[^"]*"' "$dcfile" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
    # devcontainer.json may use VS Code's ${localWorkspaceFolderBasename} variable
    # instead of a literal path; resolve it to the real folder name here since
    # we already know it, rather than passing the unresolved template through.
    wsfolder="${wsfolder//\$\{localWorkspaceFolderBasename\}/$name}"
  fi
  settingsfile="${d}.vscode/settings.json"
  title=""
  bg=""
  fg=""
  if [ -f "$settingsfile" ]; then
    title="$(grep -o '"window.title"[[:space:]]*:[[:space:]]*"[^"]*"' "$settingsfile" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
    bg="$(grep -o '"titleBar.activeBackground"[[:space:]]*:[[:space:]]*"[^"]*"' "$settingsfile" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
    fg="$(grep -o '"titleBar.activeForeground"[[:space:]]*:[[:space:]]*"[^"]*"' "$settingsfile" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
  fi
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$name" "$hasdc" "$wsfolder" "$title" "$bg" "$fg"
done
