// Instantiated by `verilog_top.sv`. Declared non-ANSI on purpose: the regex
// generator this replaced only matched the ANSI form and emitted no ports at
// all here.
module verilog_inner (clk, q);
    input clk;
    output q;

    reg staged;

    assign q = staged;
endmodule
