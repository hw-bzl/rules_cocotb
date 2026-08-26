"""Verifies transitive stub graph: the testbench stub imports the DUT stub.

`counter_tb.vhd` instantiates `entity work.counter`. Because
`cocotb_stubgen`'s aspect walks `deps` and threads PyInfo transitively,
the DUT stub module (`tests.stubgen.counter`) is on `sys.path` alongside
the testbench stub — otherwise the `from tests.stubgen.counter import Counter`
line at the top of the generated testbench stub would fail at import time.
"""

from tests.stubgen.counter import Counter
from tests.stubgen.counter_tb import CounterTb


def test_counter_tb_dut_field_types_to_dut_class() -> None:
    """The testbench's `dut` field carries the DUT class as its type — cross-file."""
    assert CounterTb.__annotations__["dut"] is Counter
