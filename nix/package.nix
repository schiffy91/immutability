{ pkgs, inputs }:
let
  btrcpy = inputs.btrc.packages.${pkgs.stdenv.hostPlatform.system}.btrcpy;
in {
  immutability = pkgs.stdenv.mkDerivation {  # one static-ish program: it runs in the initrd, with nothing wrapped around it
    name = "immutability";
    src = ../src;
    nativeBuildInputs = [ btrcpy ];
    dontConfigure = true;
    buildPhase = ''
      export BTRC_CACHE_DIR="$TMPDIR/btrc-cache" BTRC_STATE_DIR="$TMPDIR/btrc-state" BTRC_PKG_CACHE="$TMPDIR/btrc-pkgs"
      btrcpy --strict-imports Immutability.btrc -o immutability.c
      $CC -std=c11 -O2 immutability.c -lm -lpthread -o immutability
    '';
    installPhase = ''
      install -Dm755 immutability $out/bin/immutability
    '';
  };
}
