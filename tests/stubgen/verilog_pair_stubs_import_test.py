"""Verilog stubs: instantiation typing, non-ANSI ports, internal signals.

`verilog_top.sv` and `verilog_inner.sv` share one `verilog_library`, and
`verilog_top` instantiates `verilog_inner`. Everything asserted here comes
from `verible-verilog-syntax`; the regex generator that preceded it emitted
no instantiation fields at all and could not read `verilog_inner`'s non-ANSI
port list.
"""

from typing import Any

from tests.stubgen.verilog_inner import VerilogInner
from tests.stubgen.verilog_top import VerilogTop


def test_instantiation_typed_against_sibling_class() -> None:
    """The instance field carries the sibling stub class, not `Any`."""
    assert VerilogTop.__annotations__["u_inner"] is VerilogInner


def test_parameters_ports_and_nets_are_all_present() -> None:
    """Declaration order is preserved: parameters, ports, then nets."""
    assert list(VerilogTop.__annotations__) == ["WIDTH", "clk", "q", "idle", "u_inner"]


def test_non_ansi_ports_are_extracted() -> None:
    """`module verilog_inner (clk, q); input clk;` resolves to real ports."""
    assert list(VerilogInner.__annotations__) == ["clk", "q", "staged"]
    assert VerilogInner.__annotations__["clk"] is Any
