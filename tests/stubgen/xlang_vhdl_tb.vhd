library ieee;
use ieee.std_logic_1164.all;

entity xlang_vhdl_tb is
end entity xlang_vhdl_tb;

architecture tb of xlang_vhdl_tb is
    signal clk : std_logic := '0';
    signal q   : std_logic;
begin
    -- Cross-language: `xlang_verilog_helper` lives in a `verilog_library`
    -- wired in through `verilog_deps`, not `deps`. Aspect must walk that
    -- edge to type this instantiation.
    helper_inst : entity work.xlang_verilog_helper
        port map (
            clk => clk,
            q   => q
        );
end architecture tb;
