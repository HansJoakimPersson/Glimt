-- VHDL counter interface and implementation.
library ieee;
use ieee.std_logic_1164.all;

entity counter is
  port (clk : in std_logic; count : out integer);
end entity;

architecture rtl of counter is
  constant label_text : string := "counter";
begin
  process(clk)
  begin
    if rising_edge(clk) then
      count <= 42;
    end if;
  end process;
end architecture;
