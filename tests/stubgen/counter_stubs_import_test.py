"""Verifies the cocotb_stubgen output is materialised on sys.path."""

from cocotb.handle import LogicArrayObject, LogicObject

from tests.stubgen.counter import Counter


def test_counter_protocol_has_ports() -> None:
    """The stub Protocol carries the VHDL entity's ports as annotations."""
    assert Counter.__annotations__ == {
        "clk": LogicObject,
        "rst": LogicObject,
        "enable": LogicObject,
        "count": LogicArrayObject,
        "count_reg": LogicArrayObject,
    }
