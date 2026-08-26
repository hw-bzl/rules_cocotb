library ieee;
use ieee.std_logic_1164.all;

entity ext_dep_dut_tb is
end entity ext_dep_dut_tb;

architecture tb of ext_dep_dut_tb is
    signal clk  : std_logic := '0';
    signal rst  : std_logic := '0';
    signal data : std_logic_vector(7 downto 0);
begin
    dut : entity work.ext_dep_dut
        port map (
            clk  => clk,
            rst  => rst,
            data => data
        );
end architecture tb;
