"""Regression: aspect must follow `verilog_deps` / `vhdl_deps` cross-language edges.

`xlang_vhdl_tb.vhd` (in a `vhdl_library`) instantiates
`xlang_verilog_helper` (in a `verilog_library` reached only via
`verilog_deps`). Before the aspect walked those attrs, the metadata for
`XlangVerilogHelper` never reached the testbench's render action, so
`helper_inst` downgraded to `Any` regardless of whether a
`cocotb_stubgen` covered the Verilog side.
"""

from tests.stubgen.xlang_verilog_helper import XlangVerilogHelper
from tests.stubgen.xlang_vhdl_tb import XlangVhdlTb


def test_xlang_helper_inst_typed_via_verilog_deps_walk() -> None:
    """`helper_inst` carries the Verilog stub class, not `Any`."""
    assert XlangVhdlTb.__annotations__["helper_inst"] is XlangVerilogHelper
