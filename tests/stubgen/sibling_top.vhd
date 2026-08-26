library ieee;
use ieee.std_logic_1164.all;

entity sibling_top is
    port (
        clk_in : in  std_logic;
        q_out  : out std_logic
    );
end entity sibling_top;

architecture rtl of sibling_top is
begin
    -- Same-library instantiation. Regression: this must resolve to
    -- SiblingInner (not Any) via the sibling-metadata pass.
    inner_inst : entity work.sibling_inner
        port map (
            clk => clk_in,
            q   => q_out
        );
end architecture rtl;
