-------------------------------------------------------------------------------
-- Title      : 
-------------------------------------------------------------------------------
-- File       : Pgp1p250GbpsPkg.vhd
-- Author     : Larry Ruckman  <ruckman@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2014-03-28
-- Last update: 2016-08-25
-- Platform   :
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-------------------------------------------------------------------------------
-- This file is part of 'SLAC PGP Gen3 Card'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'SLAC PGP Gen3 Card', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;

use work.StdRtlPkg.all;

package Pgp1p250GbpsPkg is

   -- PGP Configurations
   constant PGP_RATE_C : real := 1.250E+9;  -- 1.25 Gbps
   constant CLK_RATE_INT_C : integer := 62500000;

   -- MGT Configurations
   constant CLK_DIV_C        : integer    := 4;
   constant CLK25_DIV_C      : integer    := 5;                         -- Set by wizard   
   constant RX_OS_CFG_C      : bit_vector := "0000010000000";           -- Set by wizard
   constant RXCDR_CFG_C      : bit_vector := x"0000107FE106001041010";  -- Set by wizard
   constant RXLPM_INCM_CFG_C : bit        := '0';                       -- Set by wizard
   constant RXLPM_IPCM_CFG_C : bit        := '1';                       -- Set by wizard       

   -- Quad PLL Configurations
   constant QPLL_FBDIV_IN_C      : integer := 4;
   constant QPLL_FBDIV_45_IN_C   : integer := 5;
   constant QPLL_REFCLK_DIV_IN_C : integer := 1;

   -- MMCM Configurations
   constant MMCM_CLKIN_PERIOD_C  : real    := 8.000;
   constant MMCM_CLKFBOUT_MULT_C : real    := 12.500;
   constant MMCM_GTCLK_DIVIDE_C  : real    := 12.500;
   constant MMCM_PGPCLK_DIVIDE_C : natural := 25;
   
end package Pgp1p250GbpsPkg;
