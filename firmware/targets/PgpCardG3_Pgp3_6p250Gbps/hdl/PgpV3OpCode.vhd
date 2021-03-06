-------------------------------------------------------------------------------
-- Title      : 
-------------------------------------------------------------------------------
-- File       : PgpV3OpCode.vhd
-- Author     : Larry Ruckman  <ruckman@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2013-07-02
-- Last update: 2018-10-08
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

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;
use work.Pgp3Pkg.all;
use work.PgpCardG3Pkg.all;

entity PgpV3OpCode is
   generic (
      TPD_G : time := 1 ns);
   port (
      -- Software OP-Code and Data
      pgpOpCodeEn   : in  sl;
      pgpOpCode     : in  slv(7 downto 0);
      pgpLocData    : in  slv(7 downto 0);
      -- Configurations
      runDelay      : in  slv(31 downto 0);
      acceptDelay   : in  slv(31 downto 0);
      acceptCntRst  : in  sl;
      evrOpCodeMask : in  sl;
      evrSyncSel    : in  sl;
      evrSyncEn     : in  sl;
      evrSyncWord   : in  slv(31 downto 0);
      evrSyncStatus : out sl;
      acceptCnt     : out slv(31 downto 0);
      -- External Interfaces
      evrToPgp      : in  EvrToPgpType;
      -- PGP core interface
      pgpTxIn       : out Pgp3TxInType;
      pgpTxOut      : in  Pgp3TxOutType;
      -- RX Virtual Channel Interface
      trigLutIn     : in  TrigLutInArray(0 to 3);
      trigLutOut    : out TrigLutOutArray(0 to 3);
      -- Global Signals
      pciClk        : in  sl;
      pciRst        : in  sl;
      pgpTxClk      : in  sl;
      pgpTxRst      : in  sl;
      pgpRxClk      : in  sl;
      pgpRxRst      : in  sl;
      evrClk        : in  sl;
      evrRst        : in  sl);
end PgpV3OpCode;

architecture rtl of PgpV3OpCode is

   type RegType is record
      evrSyncEn : sl;
      ready     : sl;
      valid     : sl;
      we        : sl;
      trigAddr  : slv(7 downto 0);
      waddr     : slv(7 downto 0);
      acceptCnt : slv(31 downto 0);
      seconds   : slv(31 downto 0);
      offset    : slv(31 downto 0);
   end record;

   constant REG_INIT_C : RegType := (
      evrSyncEn => '0',
      ready     => '0',
      valid     => '0',
      we        => '0',
      trigAddr  => (others => '0'),
      waddr     => (others => '0'),
      acceptCnt => (others => '0'),
      seconds   => (others => '0'),
      offset    => (others => '0'));

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

   signal runTrig        : sl;
   signal opCodeEn       : sl;
   signal opCodeEnFifoWr : sl;
   signal opCodeFifoDin  : slv(47 downto 0);
   signal locData        : slv(7 downto 0);
   signal opCode         : slv(7 downto 0);
   signal seconds        : slv(31 downto 0);

   signal delay   : EvrToPgpType;
   signal fromEvr : EvrToPgpType;

begin

   ----------------
   -- Delay Modules
   ----------------
   EvrOpCodeDelay_0 : entity work.EvrOpCodeDelay
      port map(
         evrClk             => evrClk,
         evrRst             => evrRst,
         delayConfig        => runDelay,
         din(64)            => evrToPgp.run,
         din(63 downto 32)  => evrToPgp.seconds,
         din(31 downto 0)   => evrToPgp.offset,
         dout(64)           => delay.run,
         dout(63 downto 32) => delay.seconds,
         dout(31 downto 0)  => delay.offset);

   EvrOpCodeDelay_1 : entity work.EvrOpCodeDelay
      port map(
         evrClk             => evrClk,
         evrRst             => evrRst,
         delayConfig        => acceptDelay,
         din(64)            => evrToPgp.accept,
         din(63 downto 32)  => (others => '0'),
         din(31 downto 0)   => (others => '0'),
         dout(64)           => delay.accept,
         dout(63 downto 32) => open,
         dout(31 downto 0)  => open);

   -------------------------------
   -- Output Bus Mapping
   -------------------------------
   runTrig                     <= fromEvr.run and not(evrOpCodeMask);
   pgpTxIn.disable             <= '0';
   pgpTxIn.flowCntlDis         <= '0';
   pgpTxIn.skpInterval         <= (others => '0');
   pgpTxIn.opCodeNumber        <= (others => '0');
   opCodeEnFifoWr              <= runTrig or opCodeEn;
   opCodeFifoDin(47 downto 16) <= (others => '0');
   opCodeFifoDin(15 downto 8)  <= r.trigAddr when(opCodeEn = '0') else opCode;
   opCodeFifoDin(7 downto 0)   <= locData;

   U_OpCode_Fifo : entity work.FifoSync
      generic map(
         FWFT_EN_G   => true,
         BRAM_EN_G   => false,
         DATA_WIDTH_G => 48,
         ADDR_WIDTH_G => 4)
      port map(
         rst    => pgpTxRst,
         clk    => pgpTxClk,
         -- Write Ports (wr_clk domain)
         wr_en  => opCodeEnFifoWr,
         din    => opCodeFifoDin,
         -- Read Ports (rd_clk domain)
         rd_en  => pgpTxOut.opCodeReady,
         valid  => pgpTxIn.opCodeEn,
         dout   => pgpTxIn.opCodeData);

   -------------------------------
   -- Synchronization
   ------------------------------- 
   SynchronizerFifo_0 : entity work.SynchronizerFifo
      generic map(
         DATA_WIDTH_G => 8)
      port map(
         -- Write Ports (wr_clk domain)
         wr_clk => pciClk,
         wr_en  => pgpOpCodeEn,
         din    => pgpOpCode,
         -- Read Ports (rd_clk domain)
         rd_clk => pgpTxClk,
         rd_en  => '1',
         valid  => opCodeEn,
         dout   => opCode);

   SynchronizerFifo_1 : entity work.SynchronizerFifo
      generic map(
         DATA_WIDTH_G => 64)
      port map(
         -- Write Ports (wr_clk domain)
         wr_clk             => evrClk,
         wr_en              => delay.run,
         din(63 downto 32)  => delay.seconds,
         din(31 downto 0)   => delay.offset,
         -- Read Ports (rd_clk domain)
         rd_clk             => pgpTxClk,
         rd_en              => '1',
         valid              => fromEvr.run,
         dout(63 downto 32) => fromEvr.seconds,
         dout(31 downto 0)  => fromEvr.offset);

   SynchronizerFifo_2 : entity work.SynchronizerFifo
      generic map(
         DATA_WIDTH_G => 1)
      port map(
         -- Write Ports (wr_clk domain)
         wr_clk  => evrClk,
         wr_en   => delay.accept,
         din(0)  => '0',
         -- Read Ports (rd_clk domain)
         rd_clk  => pgpTxClk,
         rd_en   => '1',
         valid   => fromEvr.accept,
         dout(0) => open);

   SynchronizerFifo_3 : entity work.SynchronizerFifo
      generic map(
         DATA_WIDTH_G => 32)
      port map(
         -- Write Ports (wr_clk domain)
         wr_clk => evrClk,
         din    => evrToPgp.seconds,
         -- Read Ports (rd_clk domain)
         rd_clk => pgpTxClk,
         dout   => seconds);

   SynchronizerFifo_4 : entity work.SynchronizerFifo
      generic map(
         DATA_WIDTH_G => 8)
      port map(
         -- Write Ports (wr_clk domain)
         wr_clk => pciClk,
         din    => pgpLocData,
         -- Read Ports (rd_clk domain)
         rd_clk => pgpTxClk,
         dout   => locData);

   -------------------------------
   -- Look up Table
   -------------------------------
   GEN_LUT :
   for vc in 0 to 3 generate
      SimpleDualPortRam_Inst : entity work.SimpleDualPortRam
         generic map(
            BRAM_EN_G    => true,  -- Using BRAM to make the "Place and Route" faster
            DATA_WIDTH_G => 97,
            ADDR_WIDTH_G => 8)
         port map (
            -- Port A
            clka                => pgpTxClk,
            wea                 => r.we,
            addra               => r.waddr,
            dina(96)            => r.valid,
            dina(95 downto 64)  => r.seconds,
            dina(63 downto 32)  => r.offset,
            dina(31 downto 0)   => r.acceptCnt,
            -- Port B
            clkb                => pgpRxClk,
            addrb               => trigLutIn(vc).raddr,
            doutb(96)           => trigLutOut(vc).accept,
            doutb(95 downto 64) => trigLutOut(vc).seconds,
            doutb(63 downto 32) => trigLutOut(vc).offset,
            doutb(31 downto 0)  => trigLutOut(vc).acceptCnt);
   end generate GEN_LUT;

   -------------------------------
   -- Look Up Table Writing Process
   -------------------------------     
   comb : process (acceptCntRst, evrSyncEn, evrSyncSel, evrSyncWord, fromEvr,
                   pgpTxRst, r, seconds) is
      variable v : RegType;
   begin
      -- Latch the current value
      v := r;

      -- Reset the strobes
      v.we    := '0';
      v.valid := '0';

      -- Check if sync word detected or ASYNC mode
      if (evrSyncWord = seconds) or (evrSyncSel = '0') then
         -- Update the evrSyncEn
         v.evrSyncEn := evrSyncEn;
      end if;

      -- Check for a trigger
      if (fromEvr.run = '1') then
         -- Clear the trigLutOut.accept bit
         v.we       := '1';
         v.waddr    := r.trigAddr;
         -- Latch the Values
         v.seconds  := fromEvr.seconds;
         v.offset   := fromEvr.offset;
         -- Increment the trigAddr
         v.trigAddr := r.trigAddr + 1;
         -- Set the ready for accept flag
         v.ready    := v.evrSyncEn;
      end if;

      -----------------------------------------------------------------
      -- Check for valid accept bit
      -- Note: The trigger bit must always comes before the accept bit.
      -----------------------------------------------------------------          
      if (fromEvr.accept = '1') and (r.ready = '1') then
         -- Set the trigLutOut.accept bit
         v.we        := '1';
         v.valid     := '1';
         -- Increment the counter
         v.acceptCnt := r.acceptCnt + 1;
         -- Clear the ready for accept flag
         v.ready     := '0';
      end if;

      -- Check for counter reset
      if acceptCntRst = '1' then
         v.acceptCnt := (others => '0');
      end if;

      -- Reset
      if (pgpTxRst = '1') then
         v := REG_INIT_C;
      end if;

      -- Register the variable for next clock cycle
      rin <= v;

      -- Outputs
      evrSyncStatus <= r.evrSyncEn;
      acceptCnt     <= r.acceptCnt;

   end process comb;

   seq : process (pgpTxClk) is
   begin
      if rising_edge(pgpTxClk) then
         r <= rin after TPD_G;
      end if;
   end process seq;

end rtl;
