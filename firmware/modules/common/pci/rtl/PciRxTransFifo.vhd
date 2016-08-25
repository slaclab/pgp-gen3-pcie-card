-------------------------------------------------------------------------------
-- Title      : 
-------------------------------------------------------------------------------
-- File       : PciRxTransFifo.vhd
-- Author     : Larry Ruckman  <ruckman@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2014-06-23
-- Last update: 2016-08-25
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------
-- Copyright (c) 2016 SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.SsiPkg.all;
use work.PciPkg.all;

entity PciRxTransFifo is
   generic (
      TPD_G : time := 1 ns);
   port (
      -- Streaming RX Interface
      sAxisClk    : in  sl;
      sAxisRst    : in  sl;
      sAxisMaster : in  AxiStreamMasterType;
      sAxisSlave  : out AxiStreamSlaveType;
      -- Streaming RX Interface
      pciClk      : in  sl;
      pciRst      : in  sl;
      mAxisMaster : out AxiStreamMasterType;
      mAxisSlave  : in  AxiStreamSlaveType;
      tranRd      : in  sl;
      tranValid   : out sl;
      tranSubId   : out slv(3 downto 0);
      tranEofe    : out sl;
      tranLength  : out slv(8 downto 0);
      tranCnt     : out slv(8 downto 0));
end PciRxTransFifo;

architecture rtl of PciRxTransFifo is

   type StateType is (
      IDLE_S,
      SEND_S);  

   type RegType is record
      sof        : sl;
      tranWr     : sl;
      tranSubId  : slv(3 downto 0);
      tranCnt    : slv(8 downto 0);
      tranLength : slv(8 downto 0);
      tranEofe   : sl;
      cnt        : slv(8 downto 0);
      size       : slv(8 downto 0);
      sAxisSlave : AxiStreamSlaveType;
      axisMaster : AxiStreamMasterType;
      state      : StateType;
   end record RegType;
   
   constant REG_INIT_C : RegType := (
      sof        => '1',
      tranWr     => '0',
      tranSubId  => (others => '0'),
      tranCnt    => (others => '0'),
      tranLength => (others => '0'),
      tranEofe   => '0',
      cnt        => toSlv(1, 9),
      size       => toSlv(1, 9),
      sAxisSlave => AXI_STREAM_SLAVE_INIT_C,
      axisMaster => AXI_STREAM_MASTER_INIT_C,
      state      => IDLE_S);

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

   signal reset      : sl;
   signal tranPause  : sl;
   signal axisMaster : AxiStreamMasterType;
   signal axisCtrl   : AxiStreamCtrlType;

   attribute dont_touch      : string;
   attribute dont_touch of r : signal is "true";
   
begin

   comb : process (axisCtrl, r, reset, sAxisMaster, tranPause) is
      variable v : RegType;
   begin
      -- Latch the current value
      v := r;

      -- Reset strobing signals
      v.tranWr := '0';
      ssiResetFlags(v.axisMaster);

      -- Set the ready flag
      v.sAxisSlave.tReady := sAxisMaster.tValid and not(axisCtrl.pause) and not(tranPause);

      -- Update the transaction length
      v.tranLength := r.cnt;

      -- State Machine
      case r.state is
         ----------------------------------------------------------------------
         when IDLE_S =>
            -- Check if moving data
            if v.sAxisSlave.tReady = '1' then
               -- Check the flag
               if r.sof = '1' then
                  -- Check for start of frame bit
                  if ssiGetUserSof(AXIS_32B_CONFIG_C, sAxisMaster) = '1' then
                     -- Reset the flags
                     v.sof        := '0';
                     v.tranEofe   := '0';
                     -- Latch the FIFO data
                     v.axisMaster := sAxisMaster;
                     -- Latch the transaction data
                     v.tranSubId  := sAxisMaster.tDest(3 downto 0);
                     -- Check tLast
                     if sAxisMaster.tLast = '1' then
                        -- Update the EOFE field
                        v.tranEofe := ssiGetUserEofe(AXIS_32B_CONFIG_C, sAxisMaster);
                        -- Write to the transaction FIFO
                        v.tranWr   := '1';
                        -- Preset the counter
                        v.cnt      := toSlv(1, 9);
                        -- Set the flag
                        v.sof      := '1';
                     else
                        -- Reset the counter              
                        v.tranCnt          := (others => '0');
                        -- Reset the tKeep
                        v.axisMaster.tKeep := x"FFFF";
                        -- Preset the counter
                        v.cnt              := toSlv(2, 9);
                        -- Next State
                        v.state            := SEND_S;
                     end if;
                  end if;
               else
                  -- Latch the FIFO data
                  v.axisMaster := sAxisMaster;
                  -- Check tLast
                  if sAxisMaster.tLast = '1' then
                     -- Update the EOFE field
                     v.tranEofe := ssiGetUserEofe(AXIS_32B_CONFIG_C, sAxisMaster);
                     -- Write to the transaction FIFO
                     v.tranWr   := '1';
                     -- Preset the counter
                     v.cnt      := toSlv(1, 9);
                     -- Set the flag
                     v.sof      := '1';
                  else
                     -- Reset the counter              
                     v.tranCnt          := (others => '0');
                     -- Reset the tKeep
                     v.axisMaster.tKeep := x"FFFF";
                     -- Preset the counter
                     v.cnt              := toSlv(2, 9);
                     -- Next State
                     v.state            := SEND_S;
                  end if;
               end if;
            end if;
         ----------------------------------------------------------------------
         when SEND_S =>
            -- Check if moving data
            if v.sAxisSlave.tReady = '1' then
               -- Increment the counter
               v.cnt := r.cnt + 1;
               -- MUX the data bus
               if r.axisMaster.tKeep = x"FFFF" then
                  -- Latch DW0
                  v.axisMaster.tData(31 downto 0)   := sAxisMaster.tData(31 downto 0);
                  -- Reset DW[3:1]
                  v.axisMaster.tData(127 downto 32) := (others => '0');
                  -- Set AXIS tKeep
                  v.axisMaster.tKeep                := x"000F";
               elsif r.axisMaster.tKeep = x"000F" then
                  -- Latch DW1
                  v.axisMaster.tData(63 downto 32) := sAxisMaster.tData(31 downto 0);
                  -- Set AXIS tKeep
                  v.axisMaster.tKeep               := x"00FF";
               elsif r.axisMaster.tKeep = x"00FF" then
                  -- Latch DW2
                  v.axisMaster.tData(95 downto 64) := sAxisMaster.tData(31 downto 0);
                  -- Set AXIS tKeep
                  v.axisMaster.tKeep               := x"0FFF";
               else
                  -- Latch DW3
                  v.axisMaster.tData(127 downto 96) := sAxisMaster.tData(31 downto 0);
                  -- Set AXIS tKeep
                  v.axisMaster.tKeep                := x"FFFF";
                  -- Write the to FIFO
                  v.axisMaster.tValid               := '1';
                  -- Increment the counter
                  v.tranCnt                         := r.tranCnt + 1;
               end if;
               -- Check the counter and tLast
               if (r.cnt = PCIE_MAX_RX_TRANS_LENGTH_C) or (sAxisMaster.tLast = '1') then
                  -- Check for EOF flag 
                  if (sAxisMaster.tLast = '1') then
                     -- Update the EOFE field
                     v.tranEofe := ssiGetUserEofe(AXIS_32B_CONFIG_C, sAxisMaster);
                  end if;
                  -- Set the flag
                  v.sof               := sAxisMaster.tLast;
                  -- Write to the transaction FIFO
                  v.tranWr            := '1';
                  -- Preset the counter
                  v.cnt               := toSlv(1, 9);
                  -- Write the to FIFO
                  v.axisMaster.tValid := '1';
                  -- Set the tLast flag
                  v.axisMaster.tLast  := sAxisMaster.tLast;
                  -- Prevent the increment
                  v.tranCnt           := r.tranCnt;
                  -- Next State
                  v.state             := IDLE_S;
               end if;
            end if;
      ----------------------------------------------------------------------
      end case;


      -- Reset
      if (reset = '1') then
         v := REG_INIT_C;
      end if;

      -- Register the variable for next clock cycle
      rin <= v;

      -- Outputs
      sAxisSlave <= v.sAxisSlave;
      axisMaster <= reverseOrderPcie(r.axisMaster);
      
   end process comb;

   seq : process (sAxisClk) is
   begin
      if rising_edge(sAxisClk) then
         r <= rin after TPD_G;
      end if;
   end process seq;

   U_RstSync : entity work.RstSync
      generic map (
         TPD_G => TPD_G)
      port map (
         clk      => sAxisClk,
         asyncRst => pciRst,
         syncRst  => reset);   

   FIFO_DATA : entity work.AxiStreamFifo
      generic map (
         -- General Configurations
         TPD_G               => TPD_G,
         PIPE_STAGES_G       => 1,
         SLAVE_READY_EN_G    => false,
         VALID_THOLD_G       => 1,
         -- FIFO configurations
         CASCADE_SIZE_G      => 1,
         BRAM_EN_G           => true,
         XIL_DEVICE_G        => "7SERIES",
         USE_BUILT_IN_G      => false,
         GEN_SYNC_FIFO_G     => false,
         ALTERA_SYN_G        => false,
         ALTERA_RAM_G        => "M9K",
         FIFO_ADDR_WIDTH_G   => 9,
         FIFO_FIXED_THRESH_G => true,
         FIFO_PAUSE_THRESH_G => 500,
         SLAVE_AXI_CONFIG_G  => PCI_AXIS_CONFIG_C,
         MASTER_AXI_CONFIG_G => PCI_AXIS_CONFIG_C) 
      port map (
         -- Slave Port
         sAxisClk    => sAxisClk,
         sAxisRst    => reset,
         sAxisMaster => axisMaster,
         sAxisCtrl   => axisCtrl,
         -- Master Port
         mAxisClk    => pciClk,
         mAxisRst    => pciRst,
         mAxisMaster => mAxisMaster,
         mAxisSlave  => mAxisSlave);   

   Fifo_Trans : entity work.FifoAsync
      generic map (
         TPD_G        => TPD_G,
         BRAM_EN_G    => true,
         FWFT_EN_G    => true,
         DATA_WIDTH_G => 23,
         ADDR_WIDTH_G => 10,
         FULL_THRES_G => 1000)
      port map (
         rst                => reset,
         --Write Ports (wr_clk domain)
         wr_clk             => sAxisClk,
         wr_en              => r.tranWr,
         din(22 downto 19)  => r.tranSubId,
         din(18)            => r.tranEofe,
         din(17 downto 9)   => r.tranLength,
         din(8 downto 0)    => r.tranCnt,
         prog_full          => tranPause,
         --Read Ports (rd_clk domain)
         rd_clk             => pciClk,
         rd_en              => tranRd,
         dout(22 downto 19) => tranSubId,
         dout(18)           => tranEofe,
         dout(17 downto 9)  => tranLength,
         dout(8 downto 0)   => tranCnt,
         valid              => tranValid);

end rtl;
