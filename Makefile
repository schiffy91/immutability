# Local development. The tests import btrc's testkit as a package; a Nix build places it at tests/testkit, and
# here it is linked there from the btrc this repository's lock names, for the editor and a local compiler.
.PHONY: testkit lint unit vm
testkit: tests/testkit
tests/testkit: flake.lock
	ln -sfn "$$(nix eval --raw --no-warn-dirty --inputs-from . 'btrc#lib.testkit')" $@
lint:
	nix flake check --no-build
unit:
	ci/checks.sh unit
vm:
	ci/checks.sh vm
