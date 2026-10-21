"""Building blocks for rules that build a cocotb simulator themselves.

A rule that builds a test's simulator itself uses these to build it exactly
as `cocotb_test` does. Read the test's module and settings from its
`CocotbTestInfo`, and its simulator from the cocotb toolchain's `simulators`.
"""

load(
    "//cocotb/private:cocotb_simulators.bzl",
    _CocotbSimVerilatorInfo = "CocotbSimVerilatorInfo",
)
load(
    "//cocotb/private/simulators:cocotb_sim_utils.bzl",
    _collect_hdl_sources = "collect_hdl_sources",
)
load(
    "//cocotb/private/simulators:cocotb_verilator.bzl",
    _verilator_cc_inputs = "verilator_cc_inputs",
    _verilator_flags = "verilator_flags",
)

CocotbSimVerilatorInfo = _CocotbSimVerilatorInfo
collect_hdl_sources = _collect_hdl_sources
verilator_cc_inputs = _verilator_cc_inputs
verilator_flags = _verilator_flags
