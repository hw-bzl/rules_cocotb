library ieee;
use ieee.std_logic_1164.all;

entity sibling_inner is
    port (
        clk : in  std_logic;
        q   : out std_logic
    );
end entity sibling_inner;
