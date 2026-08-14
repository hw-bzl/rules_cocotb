"""Cocotb tests for the VHDL `counter` module, DUT typed via cocotb_stubgen."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from tests.stubgen.counter import Counter


@cocotb.test()
async def test_counter_reset(dut: Counter) -> None:
    """Verify the counter resets to zero."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    dut.rst.value = 1
    dut.enable.value = 0
    await ClockCycles(dut.clk, 3)

    count = int(dut.count.value)
    assert count == 0, f"Counter should be 0 after reset, got {count}"


@cocotb.test()
async def test_counter_counts(dut: Counter) -> None:
    """Verify the counter increments when enabled."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    dut.rst.value = 1
    dut.enable.value = 0
    await ClockCycles(dut.clk, 2)

    dut.rst.value = 0
    dut.enable.value = 1
    await RisingEdge(dut.clk)

    for expected in range(1, 6):
        await RisingEdge(dut.clk)
        count = int(dut.count.value)
        assert count == expected, f"Counter expected {expected}, got {count}"
