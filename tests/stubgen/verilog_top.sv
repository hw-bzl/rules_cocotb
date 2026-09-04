// Sibling of `verilog_inner.sv` in one `verilog_library`.
module verilog_top #(
    parameter WIDTH = 8
) (
    input  logic clk,
    output logic q
);
    wire idle;

    verilog_inner u_inner (
        .clk(clk),
        .q  (q)
    );
endmodule
