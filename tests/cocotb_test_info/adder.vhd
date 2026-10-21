library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity adder_vhdl is
    generic (WIDTH : natural := 4);
    port (
        a, b : in  unsigned(WIDTH - 1 downto 0);
        sum  : out unsigned(WIDTH downto 0)
    );
end entity;

architecture rtl of adder_vhdl is
begin
    sum <= resize(a, WIDTH + 1) + b;
end architecture;
