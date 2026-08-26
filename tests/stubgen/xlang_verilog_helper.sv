// Small SystemVerilog module used as a `verilog_deps` cross-language edge
// on a VHDL testbench — see `xlang_vhdl_tb.vhd`.
module xlang_verilog_helper (
    input  logic clk,
    output logic q
);
    assign q = clk;
endmodule
