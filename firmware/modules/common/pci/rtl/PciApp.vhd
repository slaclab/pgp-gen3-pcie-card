-------------------------------------------------------------------------------
-- Title      : 
-------------------------------------------------------------------------------
-- File       : PciApp.vhd
-- Author     : Larry Ruckman  <ruckman@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2013-07-02
-- Last update: 2016-04-26
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-------------------------------------------------------------------------------
-- Copyright (c) 2015 SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.SsiPkg.all;
use work.PciPkg.all;
use work.PgpCardG3Pkg.all;
use work.Version.all;

entity PciApp is
   generic (
      -- PGP Configurations
      PGP_RATE_G : real);
   port (
      -- FLASH Interface 
      flashAddr        : out   slv(25 downto 0);
      flashData        : inout slv(15 downto 0);
      flashAdv         : out   sl;
      flashCe          : out   sl;
      flashOe          : out   sl;
      flashWe          : out   sl;
      -- System Signals
      serNumber        : out   slv(63 downto 0);
      cardReset        : out   sl;
      -- Register Interface
      regTranFromPci   : in    TranFromPciType;
      regObMaster      : in    AxiStreamMasterType;
      regObSlave       : out   AxiStreamSlaveType;
      regIbMaster      : out   AxiStreamMasterType;
      regIbSlave       : in    AxiStreamSlaveType;
      -- DMA Interface      
      dmaTxTranFromPci : in    TranFromPciArray(0 to 7);
      dmaRxTranFromPci : in    TranFromPciArray(0 to 7);
      dmaTxObMaster    : in    AxiStreamMasterArray(0 to 7);
      dmaTxObSlave     : out   AxiStreamSlaveArray(0 to 7);
      dmaTxIbMaster    : out   AxiStreamMasterArray(0 to 7);
      dmaTxIbSlave     : in    AxiStreamSlaveArray(0 to 7);
      dmaRxIbMaster    : out   AxiStreamMasterArray(0 to 7);
      dmaRxIbSlave     : in    AxiStreamSlaveArray(0 to 7);
      -- PCIe Interface
      cfgOut           : in    CfgOutType;
      irqIn            : out   IrqInType;
      irqOut           : in    IrqOutType;
      -- Parallel Interface
      pgpToPci         : in    PgpToPciType;
      pciToPgp         : out   PciToPgpType;
      evrToPci         : in    EvrToPciType;
      pciToEvr         : out   PciToEvrType;
      --Global Signals
      pgpClk           : in    sl;
      pgpRst           : in    sl;
      evrClk           : in    sl;
      evrRst           : in    sl;
      pciClk           : in    sl;
      pciRst           : in    sl);       
end PciApp;

architecture rtl of PciApp is

   constant DMA_SIZE_C : natural := 8;

   type RomType is array (0 to 63) of slv(31 downto 0);
   function makeStringRom return RomType is
      variable ret : RomType := (others => (others => '0'));
      variable c   : character;
   begin
      for i in BUILD_STAMP_C'range loop
         c                                                      := BUILD_STAMP_C(i);
         ret((i-1)/4)(8*((i-1) mod 4)+7 downto 8*((i-1) mod 4)) := toSlv(character'pos(c), 8);
      end loop;
      return ret;
   end function makeStringRom;
   signal buildStampString : RomType := makeStringRom;

   -- Descriptor Signals
   signal dmaRxDescToPci,
      dmaTxDescToPci : DescToPciArray(0 to (DMA_SIZE_C-1));
   signal dmaRxDescFromPci,
      dmaTxDescFromPci : DescFromPciArray(0 to (DMA_SIZE_C-1));

   -- Register Controller
   signal cardRst,
      countRst,
      reboot,
      rebootEn,
      regWrEn,
      regRdEn,
      regRxCs,
      regTxCs,
      regLocCs,
      regFlashCs,
      flashBusy,
      regBusy : sl;
   signal regBar  : slv(2 downto 0);
   signal regAddr : slv(31 downto 2);

   signal regWrData,
      regRdData,
      regRxRdData,
      regTxRdData,
      regLocRdData,
      regFlashRdData,
      rebootTimer,
      scratchPad : slv(31 downto 0);
   signal runDelay,
      acceptDelay : Slv32Array(0 to 7);

   signal serialNumber : slv(63 downto 0);

   -- Interrupt Signals
   signal irqEnable   : sl;
   signal rxDmaIrqReq : sl;
   signal txDmaIrqReq : sl;

   --PGP Signals
   signal pgpOpCodeEn   : sl;
   signal enHeaderCheck : SlVectorArray(0 to 7, 0 to 3);
   signal rxCount       : Slv4VectorArray(0 to 7, 0 to 3);
   signal cellErrorCnt,
      linkDownCnt,
      linkErrorCnt,
      fifoErrorCnt : Slv4Array(0 to 7);
   signal locLinkReady,
      remLinkReady,
      loopback,
      pgpOpCode,
      pgpTxRst,
      pgpRxRst : slv(7 downto 0);
   signal pllTxReady,
      pllRxReady,
      pllTxRst,
      pllRxRst : slv(1 downto 0);
   signal evrRunCnt : Slv32Array(7 downto 0);
   signal acceptCnt : Slv32Array(7 downto 0);

   --EVR Signals     
   signal evrPllRst     : sl;
   signal evrReset      : sl;
   signal evrLinkUp     : sl;
   signal evrEnable     : sl;
   signal evrSyncSel    : slv(7 downto 0);
   signal evrSyncEn     : slv(7 downto 0);
   signal evrSyncStatus : slv(7 downto 0);
   signal evrErrorCnt   : slv(31 downto 0);
   signal evrSeconds    : slv(31 downto 0);
   signal runCode       : Slv8Array(0 to 7);
   signal acceptCode    : Slv8Array(0 to 7);
   signal acceptCntRst  : slv(7 downto 0);
   signal evrOpCodeMask : slv(7 downto 0);
   signal evrSyncWord   : Slv32Array(0 to 7);
   signal lutDropCnt    : Slv8VectorArray(0 to 7, 0 to 3);
   
begin
   
   cardReset <= cardRst;

   -------------------------------
   -- Input/Output mapping
   -------------------------------    
   irqIn.req    <= rxDmaIrqReq or txDmaIrqReq;
   irqIn.enable <= irqEnable;
   serNumber    <= serialNumber;

   pciToPgp.pllRxRst(0)   <= pllRxRst(0) or cardRst;
   pciToPgp.pllRxRst(1)   <= pllRxRst(1) or cardRst;
   pciToPgp.pllTxRst(0)   <= pllTxRst(0) or cardRst;
   pciToPgp.pllTxRst(1)   <= pllTxRst(1) or cardRst;
   pciToPgp.countRst      <= countRst or cardRst;
   pciToPgp.loopBack      <= loopBack;
   pciToPgp.pgpOpCodeEn   <= pgpOpCodeEn;
   pciToPgp.pgpOpCode     <= pgpOpCode;
   pciToPgp.enHeaderCheck <= enHeaderCheck;
   pciToPgp.evrSyncSel    <= evrSyncSel;
   pciToPgp.evrSyncEn     <= evrSyncEn;
   pciToPgp.acceptCntRst  <= acceptCntRst;
   pciToPgp.evrOpCodeMask <= evrOpCodeMask;

   pciToEvr.countRst <= countRst or cardRst;
   pciToEvr.pllRst   <= evrPllRst or cardRst;
   pciToEvr.evrReset <= evrReset or cardRst;
   pciToEvr.enable   <= evrEnable;

   MAP_PGP_DMA_LANES :
   for lane in 0 to DMA_SIZE_C-1 generate
      
      pciToPgp.evrSyncWord(lane) <= evrSyncWord(lane);
      pciToEvr.runCode(lane)     <= runCode(lane);
      pciToEvr.acceptCode(lane)  <= acceptCode(lane);
      pciToPgp.pgpRxRst(lane)    <= pgpRxRst(lane) or cardRst;
      pciToPgp.pgpTxRst(lane)    <= pgpTxRst(lane) or cardRst;

      -- Input buses
      dmaTxIbMaster(lane) <= pgpToPci.dmaTxIbMaster(lane);
      dmaTxObSlave(lane)  <= pgpToPci.dmaTxObSlave(lane);
      dmaRxIbMaster(lane) <= pgpToPci.dmaRxIbMaster(lane);

      dmaTxDescToPci(lane) <= pgpToPci.dmaTxDescToPci(lane);
      dmaRxDescToPci(lane) <= pgpToPci.dmaRxDescToPci(lane);

      -- Output buses
      pciToPgp.dmaTxTranFromPci(lane) <= dmaTxTranFromPci(lane);
      pciToPgp.dmaRxTranFromPci(lane) <= dmaRxTranFromPci(lane);

      pciToPgp.dmaTxDescFromPci(lane) <= dmaTxDescFromPci(lane);
      pciToPgp.dmaRxDescFromPci(lane) <= dmaRxDescFromPci(lane);

      pciToPgp.dmaTxIbSlave(lane)  <= dmaTxIbSlave(lane);
      pciToPgp.dmaTxObMaster(lane) <= dmaTxObMaster(lane);
      pciToPgp.dmaRxIbSlave(lane)  <= dmaRxIbSlave(lane);

      pciToPgp.runDelay(lane)    <= runDelay(lane);
      pciToPgp.acceptDelay(lane) <= acceptDelay(lane);

   end generate MAP_PGP_DMA_LANES;

   -------------------------------
   -- Synchronization
   ------------------------------- 
   SynchronizerVector_0 : entity work.SynchronizerVector
      generic map (
         WIDTH_G => 2)
      port map (
         clk     => pciClk,
         dataIn  => pgpToPci.pllTxReady,
         dataOut => pllTxReady);

   SynchronizerVector_1 : entity work.SynchronizerVector
      generic map (
         WIDTH_G => 2)
      port map (
         clk     => pciClk,
         dataIn  => pgpToPci.pllRxReady,
         dataOut => pllRxReady);  

   SynchronizerVector_2 : entity work.SynchronizerVector
      generic map (
         WIDTH_G => 8)
      port map (
         clk     => pciClk,
         dataIn  => pgpToPci.locLinkReady,
         dataOut => locLinkReady);

   SynchronizerVector_3 : entity work.SynchronizerVector
      generic map (
         WIDTH_G => 8)
      port map (
         clk     => pciClk,
         dataIn  => pgpToPci.remLinkReady,
         dataOut => remLinkReady);          

   GEN_SYNC_LANE :
   for lane in 0 to 7 generate
      
      SynchronizerFifo_0 : entity work.SynchronizerFifo
         generic map(
            DATA_WIDTH_G => 4)
         port map(
            wr_clk => pgpClk,
            din    => pgpToPci.cellErrorCnt(lane),
            rd_clk => pciClk,
            dout   => cellErrorCnt(lane));

      SynchronizerFifo_1 : entity work.SynchronizerFifo
         generic map(
            DATA_WIDTH_G => 4)
         port map(
            wr_clk => pgpClk,
            din    => pgpToPci.linkDownCnt(lane),
            rd_clk => pciClk,
            dout   => linkDownCnt(lane));

      SynchronizerFifo_2 : entity work.SynchronizerFifo
         generic map(
            DATA_WIDTH_G => 4)
         port map(
            wr_clk => pgpClk,
            din    => pgpToPci.linkErrorCnt(lane),
            rd_clk => pciClk,
            dout   => linkErrorCnt(lane));             

      SynchronizerFifo_3 : entity work.SynchronizerFifo
         generic map(
            DATA_WIDTH_G => 4)
         port map(
            wr_clk => pgpClk,
            din    => pgpToPci.fifoErrorCnt(lane),
            rd_clk => pciClk,
            dout   => fifoErrorCnt(lane)); 

      GEN_SYNC_VC :
      for vc in 0 to 3 generate
         
         SynchronizerFifo_4 : entity work.SynchronizerFifo
            generic map(
               DATA_WIDTH_G => 4)
            port map(
               wr_clk => pgpClk,
               din    => pgpToPci.rxCount(lane, vc),
               rd_clk => pciClk,
               dout   => rxCount(lane, vc));  

         SynchronizerFifo_lutDropCnt : entity work.SynchronizerFifo
            generic map(
               DATA_WIDTH_G => 8)
            port map(
               wr_clk => pgpClk,
               din    => pgpToPci.lutDropCnt(lane, vc),
               rd_clk => pciClk,
               dout   => lutDropCnt(lane, vc));                 

      end generate GEN_SYNC_VC;

      Synchronizer_Inst : entity work.Synchronizer
         port map (
            clk     => pciClk,
            dataIn  => pgpToPci.evrSyncStatus(lane),
            dataOut => evrSyncStatus(lane));          

      SynchronizerFifo_5 : entity work.SynchronizerFifo
         generic map(
            DATA_WIDTH_G => 32)
         port map(
            wr_clk => evrClk,
            din    => evrToPci.runCodeCnt(lane),
            rd_clk => pciClk,
            dout   => evrRunCnt(lane)); 

      SynchronizerFifo_6 : entity work.SynchronizerFifo
         generic map(
            DATA_WIDTH_G => 32)
         port map(
            wr_clk => pgpClk,
            din    => pgpToPci.acceptCnt(lane),
            rd_clk => pciClk,
            dout   => acceptCnt(lane)); 

   end generate GEN_SYNC_LANE;

   Synchronizer_Inst : entity work.Synchronizer
      port map (
         clk     => pciClk,
         dataIn  => EvrToPci.linkUp,
         dataOut => evrLinkUp);   

   SynchronizerFifo_5 : entity work.SynchronizerFifo
      generic map(
         DATA_WIDTH_G => 32)
      port map(
         wr_clk => evrClk,
         din    => EvrToPci.seconds,
         rd_clk => pciClk,
         dout   => evrSeconds); 

   SynchronizerFifo_6 : entity work.SynchronizerFifo
      generic map(
         DATA_WIDTH_G => 32)
      port map(
         wr_clk => evrClk,
         din    => EvrToPci.errorCnt,
         rd_clk => pciClk,
         dout   => evrErrorCnt);          

   -------------------------------
   -- Controller Modules
   ------------------------------- 
   DeviceDna_Inst : entity work.DeviceDna
      port map (
         clk      => pciClk,
         rst      => pciRst,
         dnaValue => serialNumber,
         dnaValid => open);   

   -- Register Controller
   PciRegCtrl_Inst : entity work.PciRegCtrl
      port map (
         -- PCI Interface         
         regTranFromPci => regTranFromPci,
         regObMaster    => regObMaster,
         regObSlave     => regObSlave,
         regIbMaster    => regIbMaster,
         regIbSlave     => regIbSlave,
         -- Register Signals
         regBar         => regBar,
         regAddr        => regAddr,
         regWrEn        => regWrEn,
         regWrData      => regWrData,
         regRdEn        => regRdEn,
         regRdData      => regRdData,
         regBusy        => regBusy,
         --Global Signals
         pciClk         => pciClk,
         pciRst         => pciRst);

   -- RX Descriptor Controller
   PciRxDesc_Inst : entity work.PciRxDesc
      generic map (
         DMA_SIZE_G => DMA_SIZE_C)
      port map (
         -- RX DMA Interface
         dmaDescToPci   => dmaRxDescToPci,
         dmaDescFromPci => dmaRxDescFromPci,
         -- Register Signals
         regCs          => regRxCs,
         regAddr        => regAddr(9 downto 2),
         regWrEn        => regWrEn,
         regWrData      => regWrData,
         regRdEn        => regRdEn,
         regRdData      => regRxRdData,
         -- IRQ Request
         irqReq         => rxDmaIrqReq,
         -- Counter reset
         countReset     => countRst,
         --Global Signals
         pciClk         => pciClk,
         pciRst         => cardRst);

   -- TX Descriptor Controller
   PciTxDesc_Inst : entity work.PciTxDesc
      generic map (
         DMA_SIZE_G => DMA_SIZE_C)
      port map (
         -- TX DMA Interface
         dmaDescToPci   => dmaTxDescToPci,
         dmaDescFromPci => dmaTxDescFromPci,
         -- Register Signals
         regCs          => regTxCs,
         regAddr        => regAddr(9 downto 2),
         regWrEn        => regWrEn,
         regWrData      => regWrData,
         regRdEn        => regRdEn,
         regRdData      => regTxRdData,
         -- IRQ Request
         irqReq         => txDmaIrqReq,
         -- Counter reset
         countReset     => countRst,
         --Global Signals
         pciClk         => pciClk,
         pciRst         => cardRst);

   -- FLASH Controller
   PciFlashBpi_Inst : entity work.PciFlashBpi
      port map (
         -- FLASH Interface 
         flashAddr => flashAddr,
         flashData => flashData,
         flashAdv  => flashAdv,
         flashCe   => flashCe,
         flashOe   => flashOe,
         flashWe   => flashWe,
         -- Register Signals
         regCs     => regFlashCs,
         regAddr   => regAddr(9 downto 2),
         regWrEn   => regWrEn,
         regWrData => regWrData,
         regRdEn   => regRdEn,
         regRdData => regFlashRdData,
         regBusy   => flashBusy,
         --Global Signals
         pciClk    => pciClk,
         pciRst    => pciRst);                  

   -------------------------
   -- Register space
   -------------------------
   -- Decode address space
   regLocCs   <= '1' when (regAddr(11 downto 10) = "00") else '0';
   regRxCs    <= '1' when (regAddr(11 downto 10) = "01") else '0';
   regTxCs    <= '1' when (regAddr(11 downto 10) = "10") else '0';
   regFlashCs <= '1' when (regAddr(11 downto 10) = "11") else '0';

   -- Register to help with timing
   process (pciClk) is
   begin
      if rising_edge(pciClk) then
         regBusy <= flashBusy;
         if regAddr(11 downto 10) = "00" then
            if regAddr(9 downto 8) = "11" then
               regRdData <= buildStampString(conv_integer(regAddr(7 downto 2)));
            elsif regAddr(9 downto 2) = x"00" then
               -- Firmware Version
               regRdData <= FPGA_VERSION_C;
            elsif regAddr(9 downto 2) = x"01" then
               -- Serial Number Version (lower word)
               regRdData <= serialNumber(31 downto 0);
            elsif regAddr(9 downto 2) = x"02" then
               -- Serial Number Version (lower word)
               regRdData <= serialNumber(63 downto 32);
            elsif regAddr(9 downto 2) = x"06" then
               -- PGP baud rate in units of Mbps
               regRdData <= toSlv(getTimeRatio(PGP_RATE_G, 1.0E+6), 32);
            elsif regAddr(9 downto 2) = x"0B" then
               regRdData(31 downto 16) <= cfgOut.command;
               regRdData(15 downto 0)  <= cfgOut.Status;
            elsif regAddr(9 downto 2) = x"0C" then
               regRdData(31 downto 16) <= cfgOut.dCommand;
               regRdData(15 downto 0)  <= cfgOut.dStatus;
            elsif regAddr(9 downto 2) = x"0D" then
               regRdData(31 downto 16) <= cfgOut.lCommand;
               regRdData(15 downto 0)  <= cfgOut.lStatus;
            elsif regAddr(9 downto 2) = x"0E" then
               regRdData(26 downto 24) <= cfgOut.linkState;
               regRdData(18 downto 16) <= cfgOut.functionNumber;
               regRdData(12 downto 8)  <= cfgOut.deviceNumber;
               regRdData(7 downto 0)   <= cfgOut.busNumber;
            elsif regAddr(9 downto 2) = x"21" then
               regRdData(7 downto 0)  <= locLinkReady;
               regRdData(15 downto 8) <= remLinkReady;
            elsif regAddr(9 downto 2) = x"98" then
               regRdData(31 downto 0) <= acceptCnt(0);
            elsif regAddr(9 downto 2) = x"99" then
               regRdData(31 downto 0) <= acceptCnt(1);
            elsif regAddr(9 downto 2) = x"9A" then
               regRdData(31 downto 0) <= acceptCnt(2);
            elsif regAddr(9 downto 2) = x"9B" then
               regRdData(31 downto 0) <= acceptCnt(3);
            elsif regAddr(9 downto 2) = x"9C" then
               regRdData(31 downto 0) <= acceptCnt(4);
            elsif regAddr(9 downto 2) = x"9D" then
               regRdData(31 downto 0) <= acceptCnt(5);
            elsif regAddr(9 downto 2) = x"9E" then
               regRdData(31 downto 0) <= acceptCnt(6);
            elsif regAddr(9 downto 2) = x"9F" then
               regRdData(31 downto 0) <= acceptCnt(7);
            else
               regRdData <= regLocRdData;
            end if;
         elsif regAddr(11 downto 10) = "01" then
            regRdData <= regRxRdData;
         elsif regAddr(11 downto 10) = "10" then
            regRdData <= regTxRdData;
         else
            regRdData <= regFlashRdData;
         end if;
      end if;
   end process;

   Iprog7Series_Inst : entity work.Iprog7Series
      port map (
         clk         => pciClk,
         rst         => pciRst,
         start       => reboot,
         bootAddress => X"00000000");   

   -- Local register space
   process (pciClk)
      variable lane : integer;
      variable vc   : integer;
   begin
      if rising_edge(pciClk) then
         -- Reset the strobes
         pgpOpCodeEn  <= '0';
         acceptCntRst <= (others => '0');
         if pciRst = '1' then
            regLocRdData  <= (others => '0');
            scratchPad    <= (others => '0');
            irqEnable     <= '0';
            countRst      <= '0';
            cardRst       <= '1';
            loopBack      <= (others => '0');
            pgpOpCode     <= (others => '0');
            pgpRxRst      <= (others => '0');
            pgpTxRst      <= (others => '0');
            pllRxRst      <= (others => '0');
            pllTxRst      <= (others => '0');
            runCode       <= (others => x"00");
            acceptCode    <= (others => x"00");
            runDelay      <= (others => (others => '0'));
            acceptDelay   <= (others => (others => '0'));
            evrSyncWord   <= (others => (others => '0'));
            evrEnable     <= '0';
            evrSyncSel    <= (others => '0');
            evrSyncEn     <= (others => '0');
            evrReset      <= '0';
            evrPllRst     <= '0';
            enHeaderCheck <= (others => (others => '0'));
            reboot        <= '0';
            rebootEn      <= '0';
            rebootTimer   <= (others => '0');
            evrOpCodeMask <= (others => '0');
         else

            -- Check for enabled timer
            if rebootEn = '1' then
               if rebootTimer = toSlv(getTimeRatio(125.0E+6, 1.0), 32) then
                  reboot <= '1';
               else
                  rebootTimer <= rebootTimer + 1;
               end if;
            end if;
            -- Write
            if regLocCs = '1' then
               regLocRdData <= (others => '0');
               case regAddr(9 downto 2) is
                  -------------------------------
                  -- System Registers
                  -------------------------------
                  when x"03" =>
                     -- Scratch Pad
                     regLocRdData <= scratchPad;
                     if regWrEn = '1' then
                        scratchPad <= regWrData;
                     end if;
                  when x"04" =>
                     -- Reset Counters
                     regLocRdData(0) <= countRst;
                     regLocRdData(1) <= cardRst;
                     if regWrEn = '1' then
                        countRst <= regWrData(0);
                        cardRst  <= regWrData(1);
                     end if;
                  when x"05" =>
                     -- IRQ Enable
                     regLocRdData(1) <= irqOut.activeFlag;
                     regLocRdData(0) <= irqEnable;
                     if regWrEn = '1' then
                        irqEnable <= regWrData(0);
                     end if;
                  when x"07" =>
                     -- Reboot Enable
                     regLocRdData(0) <= rebootEn;
                     if (regWrEn = '1') and (regWrData = x"BABECAFE") then
                        rebootEn <= '1';
                     end if;
                  when x"08" =>
                     -- PGP OP-Code
                     regLocRdData(7 downto 0) <= pgpOpCode;
                     if regWrEn = '1' then
                        pgpOpCodeEn <= '1';
                        pgpOpCode   <= regWrData(7 downto 0);
                     end if;
                  -------------------------------
                  -- EVR Registers
                  -------------------------------                        
                  when x"10" =>
                     -- EVR's Link Status and acceptCnt reset
                     regLocRdData(3 downto 0)   <= x"0";
                     regLocRdData(4)            <= evrLinkUp;
                     regLocRdData(23 downto 16) <= evrOpCodeMask;
                     if regWrEn = '1' then
                        acceptCntRst  <= regWrData(15 downto 8);
                        evrOpCodeMask <= regWrData(23 downto 16);
                     end if;
                  when x"11" =>
                     -- EVR's Enable and Resets
                     regLocRdData(0)            <= evrEnable;
                     regLocRdData(1)            <= evrReset;
                     regLocRdData(2)            <= evrPllRst;
                     regLocRdData(15 downto 8)  <= evrSyncSel;
                     regLocRdData(23 downto 16) <= evrSyncEn;
                     regLocRdData(31 downto 24) <= evrSyncStatus;
                     if regWrEn = '1' then
                        evrEnable  <= regWrData(0);
                        evrReset   <= regWrData(1);
                        evrPllRst  <= regWrData(2);
                        evrSyncSel <= regWrData(15 downto 8);
                        evrSyncEn  <= regWrData(23 downto 16);
                     end if;
                  when x"12" =>
                     --EVR's Lanes Masks
                     for lane in 0 to 7 loop
                        --EVR's VC Masks
                        for vc in 0 to 3 loop
                           regLocRdData((4*lane)+vc) <= enHeaderCheck(lane, vc);
                           if regWrEn = '1' then
                              enHeaderCheck(lane, vc) <= regWrData((4*lane)+vc);
                           end if;
                        end loop;
                     end loop;
                  when x"13" =>
                     -- EVR's Error counter
                     regLocRdData(31 downto 0) <= evrErrorCnt;
                  when x"14" =>
                     -- EVR's Seconds
                     regLocRdData(31 downto 0) <= evrSeconds;
                  -------------------------------
                  -- PGP Registers
                  -------------------------------   
                  when x"20" =>
                     -- PGP's Loop Back Testing and Resets
                     regLocRdData(7 downto 0)   <= loopBack;
                     regLocRdData(15 downto 8)  <= pgpRxRst;
                     regLocRdData(23 downto 16) <= pgpTxRst;
                     regLocRdData(25 downto 24) <= pllRxRst;
                     regLocRdData(27 downto 26) <= pllTxRst;
                     regLocRdData(29 downto 28) <= pllRxReady;
                     regLocRdData(31 downto 30) <= pllTxReady;
                     if regWrEn = '1' then
                        loopBack <= regWrData(7 downto 0);
                        pgpRxRst <= regWrData(15 downto 8);
                        pgpTxRst <= regWrData(23 downto 16);
                        pllRxRst <= regWrData(25 downto 24);
                        pllTxRst <= regWrData(27 downto 26);
                     end if;
                  when others =>
                     -------------------------------
                     -- Misc. Array Registers
                     -------------------------------                     
                     for lane in 0 to 7 loop
                        --regAddr: 0x58-0x5F 
                        if (regAddr(9 downto 2) = (88+lane)) then
                           regLocRdData <= evrSyncWord(lane);
                           if regWrEn = '1' then
                              evrSyncWord(lane) <= regWrData;
                           end if;
                        end if;
                        --regAddr: 0x60-0x67 
                        if (regAddr(9 downto 2) = (96+lane)) then
                           regLocRdData(7 downto 0) <= runCode(lane);
                           if regWrEn = '1' then
                              runCode(lane) <= regWrData(7 downto 0);
                           end if;
                        end if;
                        --regAddr: 0x68-0x6F 
                        if (regAddr(9 downto 2) = (104+lane)) then
                           regLocRdData(7 downto 0) <= acceptCode(lane);
                           if regWrEn = '1' then
                              acceptCode(lane) <= regWrData(7 downto 0);
                           end if;
                        end if;
                        --regAddr: 0x70-0x77 
                        if (regAddr(9 downto 2) = (112+lane)) then
                           regLocRdData <= runDelay(lane);
                           if regWrEn = '1' then
                              runDelay(lane) <= regWrData;
                           end if;
                        end if;
                        --regAddr: 0x78-0x7F 
                        if (regAddr(9 downto 2) = (120+lane)) then
                           regLocRdData <= acceptDelay(lane);
                           if regWrEn = '1' then
                              acceptDelay(lane) <= regWrData;
                           end if;
                        end if;
                        --regAddr: 0x80-0x87 
                        if (regAddr(9 downto 2) = (128+lane)) then
                           regLocRdData(3 downto 0)   <= rxCount(lane, 0);
                           regLocRdData(7 downto 4)   <= rxCount(lane, 1);
                           regLocRdData(11 downto 8)  <= rxCount(lane, 2);
                           regLocRdData(15 downto 12) <= rxCount(lane, 3);
                           regLocRdData(19 downto 16) <= fifoErrorCnt(lane);
                           regLocRdData(23 downto 20) <= cellErrorCnt(lane);
                           regLocRdData(27 downto 24) <= linkDownCnt(lane);
                           regLocRdData(31 downto 28) <= linkErrorCnt(lane);
                        end if;
                        --regAddr: 0x88-8F
                        if (regAddr(9 downto 2) = (136+lane)) then
                           regLocRdData(31 downto 0) <= evrRunCnt(lane);
                        end if;
                        --regAddr: 0x90-0x97 
                        if (regAddr(9 downto 2) = (144+lane)) then
                           regLocRdData(7 downto 0)   <= lutDropCnt(lane, 0);
                           regLocRdData(15 downto 8)  <= lutDropCnt(lane, 1);
                           regLocRdData(23 downto 16) <= lutDropCnt(lane, 2);
                           regLocRdData(31 downto 24) <= lutDropCnt(lane, 3);
                        end if;
                     end loop;
               end case;
            end if;
         end if;
      end if;
   end process;

end rtl;
