"""Verifies the stub graph works across a Bazel module boundary.

`ext_dep_dut_tb.vhd` lives in the main workspace but instantiates
`entity work.ext_dep_dut`, which is declared in a `vhdl_library` inside
the sibling `cocotb_stubgen_ext_test` module (wired in via
`local_path_override`). For the annotation below to resolve, three
things must all be true:

* The aspect ran on the external repo's target and generated its stub.
* That stub's `PyInfo` (with the external repo's workspace_name in its
  `imports`) was threaded into the main-repo testbench's aggregated
  `PyInfo`, so the external repo shows up as a runfiles/`.pth` entry.
* The dep-metadata JSON travelled across the module boundary, letting
  the testbench's stubgen action write a typed `dut: ExtDepDut` field
  and matching import instead of downgrading to `Any`.
"""

from tests.stubgen.ext_dep_dut_tb import ExtDepDutTb


def test_ext_dep_dut_tb_dut_field_typed_from_external_module() -> None:
    """The `dut` field is typed against the external module's stub class."""
    assert ExtDepDutTb.__annotations__["dut"].__name__ == "ExtDepDut"
