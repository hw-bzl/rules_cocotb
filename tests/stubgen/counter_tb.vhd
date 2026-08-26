library ieee;
use ieee.std_logic_1164.all;

entity counter_tb is
end entity counter_tb;

architecture tb of counter_tb is
    signal clk    : std_logic := '0';
    signal rst    : std_logic := '0';
    signal enable : std_logic := '0';
    signal count  : std_logic_vector(7 downto 0);
begin
    dut : entity work.counter
        port map (
            clk    => clk,
            rst    => rst,
            enable => enable,
            count  => count
        );
end architecture tb;
