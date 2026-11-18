{ lib }: {
  persistKey = path: lib.replaceStrings [ "%2F" ] [ "!" ] (lib.strings.escapeURL (lib.removePrefix "/" path));  # a persisted path's subvolume name
}
