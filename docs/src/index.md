# rules_cocotb

Bazel rules that run [cocotb](https://github.com/cocotb/cocotb) Python
testbenches against Verilog/SystemVerilog and VHDL modules using
open-source HDL simulators (Verilator, Icarus Verilog, GHDL).

## Overview

A `cocotb_test` is a Bazel `test` target that pairs:

- a Verilog or VHDL `*_library` target (from
  [`rules_verilog`](https://github.com/hw-bzl/rules_verilog) or
  [`rules_vhdl`](https://github.com/hw-bzl/rules_vhdl)) as the
  *module under test*,
- one or more Python `cocotb` test sources, and
- a `cocotb_toolchain` that picks the simulator.

The top-level rules are documented under
[Rules](./rules.md); the per-simulator integrations live under
[Simulators](./simulators.md).

## End-to-end example

The walkthrough below builds a tiny 8-bit adder, drives it from a Python
cocotb testbench, and runs the test with Verilator.

### `MODULE.bazel`

```python
bazel_dep(name = "rules_verilog", version = "1.1.1")
bazel_dep(name = "rules_cocotb", version = "{version}")
```

`rules_cocotb` registers a default toolchain
(`//cocotb/toolchain:toolchain`) wired to Verilator (default), Icarus
Verilog, and GHDL. No further `register_toolchains` call is required to
use the bundled simulators.

### `adder.sv`

```systemverilog
module adder (
    input  [7:0] x,
    input  [7:0] y,
    input        carry_in,
    output       carry_output_bit,
    output [7:0] sum
);
    logic [8:0] result;
    assign result           = x + y + carry_in;
    assign sum              = result[7:0];
    assign carry_output_bit = result[8];
endmodule
```

### `adder_test.py`

```python
import cocotb
from cocotb.handle import HierarchyObject
from cocotb.triggers import Timer


@cocotb.test()
async def test_adder(dut: HierarchyObject) -> None:
    """Drive a handful of vectors through the 8-bit adder."""
    vectors = [
        # (x, y, carry_in, expected_sum, expected_carry_out)
        (0x00, 0x00, 0, 0x00, 0),
        (0xFF, 0x01, 0, 0x00, 1),
        (0x55, 0xAA, 1, 0x00, 1),
    ]
    for x, y, cin, exp_sum, exp_cout in vectors:
        dut.x.value = x
        dut.y.value = y
        dut.carry_in.value = cin
        await Timer(1, units="ns")
        sum_val = int(dut.sum.value)
        cout_val = int(dut.carry_output_bit.value)
        assert sum_val == exp_sum and cout_val == exp_cout, (
            f"adder mismatch for x={x:#04x} y={y:#04x} cin={cin}"
        )
```

### `BUILD.bazel`

```python
load("@rules_verilog//verilog:defs.bzl", "verilog_library")
load("@rules_cocotb//cocotb:cocotb_test.bzl", "cocotb_test")

verilog_library(
    name = "adder",
    srcs = ["adder.sv"],
)

cocotb_test(
    name = "adder_test",
    srcs = ["adder_test.py"],
    module = ":adder",
    sim = "verilator",
)
```

### Run it

```text
$ bazel test //path/to:adder_test
//path/to:adder_test                                                     PASSED
```

To rerun under Icarus instead, change `sim = "verilator"` to
`sim = "icarus"`. To swap to a VHDL toplevel, replace `verilog_library`
with `vhdl_library` from `rules_vhdl` and pick `sim = "ghdl"`.

## Going further

- The [`cocotb_test`](./cocotb_test.md) reference covers the full
  attribute set (`params`, `sim_opts`, `env`, etc.).
- The [`cocotb_toolchain`](./cocotb_toolchain.md) reference shows how to
  define a custom toolchain — for selecting a different default
  simulator, narrowing the set of simulators, or wiring in a
  bring-your-own-install `cocotb_*_sim`.
- The [`cocotb_stubgen`](./cocotb_stubgen.md) reference covers generating
  typed Python stubs from an HDL library, so a testbench's `dut`
  parameter type-checks instead of being an untyped `HierarchyObject`.
- The [Simulators](./simulators.md) section lists every built-in
  simulator integration and per-simulator status.
