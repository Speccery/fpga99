-- toplevel.vhd
-- TMS9995 project for Mini Spartan 6 board with FTDI UART
-- XC6SLX9-2TQG144
--
-- toplevel.vhd
--
-- Started 2016-03-23 (C) Erik Piehl
-- Continued after a long pause 2018-05-01 to include Paul's TMS9902.


-- Fix for windows 10, reminder how to get ISE 14.7 working on win 10.
--	https://www.youtube.com/watch?v=jBJlW40kAAU
--Fixing Project Navigator, iMPACT and License Manager
--1. Open the following directory: C:\Xilinx\14.7\ISE_DS\ISE\lib\nt64 
--2. Find and rename libPortability.dll to libPortability.dll.orig
--3. Make a copy of libPortabilityNOSH.dll (copy and paste it to the same directory) and rename it libPortability.dll
--4. Copy libPortabilityNOSH.dll again, but this time navigate to C:\Xilinx\14.7\ISE_DS\common\lib\nt64 and paste it there 
--5. in C:\Xilinx\14.7\ISE_DS\common\lib\nt64 Find and rename libPortability.dll to libPortability.dll.orig
--6. Rename libPortabilityNOSH.dll to libPortability.dll
--OK, I have fixed this, you can try in your windows.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
-- use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;


library UNISIM;
use UNISIM.vcomponents.all; -- get xilinx ram

entity toplevel is
	generic (
		real9902 : boolean := false;
		awidth : integer := 8; 
		aregs  : integer := 16
	);
  Port(
-- MINI XC6SLX9
	CLK50M  		: in std_logic;
	SW1			: in std_logic;	-- switch pushed -> high level
	SW2			: in std_logic;
	LED			: out std_logic_vector(7 downto 0);	-- high value -> LED is lit
	TX				: out std_logic; -- to FTDI CHIP
	RX				: in std_logic;  -- to FTDI CHIP
	
-- Connections to TMS9995 board
	n_RAMCE		: out std_logic;
	n_ROMCE		: out std_logic;
	CRUCLK_OUT  : out std_logic;
	n_CRU1		: out std_logic;
	n_CRU2		: out std_logic;
	
	n_MEMEN		: in std_logic;
	n_WE			: in std_logic;
	n_DBIN		: in std_logic;
	ABUS			: in std_logic_vector(15 downto 0);
	DBUS			: inout std_logic_vector(7 downto 0);
	
	CRUIN			: out STD_LOGIC;			-- output from PNR's TMS9902

-- UART routing to FTDI chip
   RX02			: out std_logic;
	TX02			: in  std_logic;
	
-- NMI signals to enable single stepping
	n_NMI			: out std_logic;
	IAQ			: in std_logic;

-- SD card interface. DI and DO are from the viewpoint of the SD card interface.
	n_SD_CS 		: out std_logic := '1';
	SD_DI			: out std_logic;
	SD_CLK		: out std_logic;
	SD_DO 		: in  std_logic;

-- MMU & other signals
	n_RESET_OUT		: out std_logic;
	RA				: out std_logic_vector(18 downto 12); -- 7 bits, let's not bring out the MSB A19
	READY			: out std_logic
	
);
end toplevel;	
	
ARCHITECTURE toplevel_architecture OF toplevel IS
	constant mmubase : std_logic_vector(15 downto 0) := x"FF40";	-- MMU's base address (memory mapped peripheral)
	constant testbas : std_logic_vector(15 downto 0) := x"FF50";	-- test reg base address (memory mapped peripheral)
	constant flagbas : std_logic_vector(15 downto 0) := x"0140";	-- Flagsel register in CRU address space
	constant sel9902 : std_logic_vector(15 downto 0) := x"0000";	-- TMS9902 start in CRU address space
	constant sel9901 : std_logic_vector(15 downto 0) := x"0040";
	constant spibase : std_logic_vector(15 downto 0) := x"FF30";	-- SPI controller

	signal reset 		  	: std_logic;
	signal reset_delay  	: std_logic_vector(15 downto 0) := x"0000";
	signal protect 		: std_logic;
	signal mapen			: std_logic;
	signal n_romen			: std_logic;
	signal selmmu        : std_logic := '0';
	signal seltest       : std_logic := '0';
	signal selflag       : std_logic := '0';
	signal selspi			: std_logic;
	signal n_romce1		: std_logic;
	signal ckon				: std_logic;
	signal ckoff			: std_logic;
	signal lrex				: std_logic;
	
	signal nmi_sync		: std_logic_vector(2 downto 0);
	signal iaq_sync		: std_logic_vector(3 downto 0);	-- Delay line to find rising edges of IAQ
	
	signal spi_clk_div	: unsigned(2 downto 0);				-- Clock divider for SPI, div 50MHz by 8
	signal spi_bit_count : unsigned(3 downto 0);				-- SPI bit counter, 8 bits are always transferred
	signal spi_shift_out : std_logic_vector(7 downto 0);	-- outgoing SPI data, changed before rising edge, MSB out
	signal spi_shift_in  : std_logic_vector(7 downto 0);	-- incoming SPI data, sampled on "rising edge"

	signal spi_state     : std_logic := '0';					-- 0 = idle, 1 = busy
	signal spi_cs			: std_logic := '1';
	
	-- flag_reg:
	--		bit 0 : n_romen - when zero, the first 32K of ROM overlay bottom 32K of address space
	--		bit 1 : mapen - when one, the MMU is enabled
	signal flag_reg 		: std_logic_vector(7 downto 0);

	type abank is array (natural range 0 to (2**aregs)-1) of std_logic_vector(awidth-1 downto 0);
	signal regs   : abank;
	signal translated_addr : std_logic_vector(awidth-1 downto 0);

	signal we_sync		: std_logic_vector(3 downto 0);	-- Delay line to sample and synchronize n_WE/n_CRUCLK 
	
	signal debug : std_logic_vector(7 downto 0);
	
	signal CRUCLK : std_logic;
	
-- TMS9902 by pnr	
	component tms9902 is
	port (
		CLK      : in  std_logic;
		nRTS     : out std_logic;
		nDSR     : in  std_logic;
		nCTS     : in  std_logic;
		nINT     : out std_logic;
		nCE      : in  std_logic;
		CRUOUT   : in  std_logic;
		CRUIN    : out std_logic;
		CRUCLK   : in  std_logic;
		XOUT     : out std_logic;
		RIN      : in  std_logic;
		S        : in  std_logic_vector(4 downto 0)
		);
	end component;	
	
	signal tms9902_cruin : std_logic;
	signal tms9902_nCE   : std_logic;
	signal tms9902_rts_cts : std_logic;
	signal pnr9902_tx : std_logic;
	signal pnr9902_rx : std_logic;
	signal n_CRU1_internal : std_logic;
	
begin

	RX02 <= RX;
	pnr9902_rx <= RX;

	process(TX02, pnr9902_tx)
	begin
		if real9902 then
			TX <= TX02;
		else
			TX <= pnr9902_tx;
		end if;
	end process;
	
	LED(0) <= not TX02;
	LED(1) <= not RX;
	LED(2) <= SW1;
	LED(3) <= SW2;
	LED(7 DOWNTO 4) <= flag_reg(3 downto 0);
	
	-- External instruction decoding
	CRUCLK_OUT  <= CRUCLK;
   CRUCLK      <= '1' when n_memen = '1' and n_we = '0' and dbus(7 downto 5) = "000" else '0';
	lrex 			<= '1' when n_memen = '1' and n_we = '0' and dbus(7 downto 5) = "111" else '0';
	ckon 			<= '1' when n_memen = '1' and n_we = '0' and dbus(7 downto 5) = "101" else '0';
	ckoff			<= '1' when n_memen = '1' and n_we = '0' and dbus(7 downto 5) = "110" else '0';

   -- Chip selects
	-- RAM is enabled whenever ROM is not enabled and memory mapped registers are not accessed
   n_RAMCE     <= '0' when n_memen = '0' and n_romce1 = '1'  
		and abus(15 downto 4) /= mmubase(15 downto 4) and abus(15 downto 4) /= testbas(15 downto 4)
		else '1';
		-- and ((abus(15) = '1' and mapen = '0') or (ra(19) = '0' and mapen = '1'))

	-- ROM is enabled if A15=0 when n_romen=0.
	-- In addition, when MMU is enabled and CPU is accessing high 512K.
	n_romce1 <= '0' when n_memen = '0' 
		and ((abus(15) = '0' and n_romen = '0') or (translated_addr(7)='1' and mapen = '1'))
		else '1';
	n_ROMCE <= n_romce1;
	
	-- CRU bus: S4=A5 S3=A4 S2=A3 S1=A2 S0=A1 CRUOUT=A0
   n_cru1_internal <= '0' when n_memen = '1' and abus(15 downto 6) = sel9902(15 downto 6) else '1';
   n_cru2      <= '0' when n_memen = '1' and abus(15 downto 6) = sel9901(15 downto 6) else '1';
	
	mapen <= flag_reg(1);
	n_romen <= flag_reg(0);
	
	-- NMI output
	n_NMI <= nmi_sync(2);
   
	-- Memory mapped peripherals inside FPGA
   -- selmmu is high when the FPGA's MMU is being accessed
   selmmu <= '1'  when abus(15 downto 4) = mmubase(15 downto 4) and n_memen = '0' else '0';
	seltest <= '1' when abus(15 downto 4) = testbas(15 downto 4) and n_memen = '0' else '0';
	selspi <= '1'  when abus(15 downto 4) = spibase(15 downto 4) and n_memen = '0' else '0';
	
	-- CRU peripherals inside the FPGA
	selflag <= '1' when abus(15 downto 4) = flagbas(15 downto 4) and n_memen = '1' else '0'; 
	
	-- Driving of SPI out of the FPGA
	SD_DI  <= spi_shift_out(7);
	SD_CLK <= spi_clk_div(2);	-- MSB of the divider
	n_SD_CS <= spi_cs;
	
  -- put the MMU design here.
	process (CLK50M, SW1)
	begin
		if SW1 = '1' then
			-- Process reset here.
			n_reset_out <= '0';
			ready <= '0';
			reset_delay <= (others => '0');
			flag_reg <= x"00";
			we_sync <= (others => '0');
			nmi_sync <= (others => '1');
			iaq_sync <= (others => '0');
			spi_state <= '0';
			spi_cs <= '1';
		elsif rising_edge(CLK50M) then
			-- take care of reset, enable zero wait states
			n_reset_out <= reset_delay(8); 
			ready 		<= reset_delay(15);
			reset_delay <= reset_delay(14 downto 0) & '1';
		
			-- write to MMU
			if selmmu = '1' and n_we = '0' then
				regs(to_integer(unsigned(abus(3 downto 0)))) <= dbus(awidth-1 downto 0);
			end if;
			
			-- write to CRU registers
			we_sync <= we_sync(2 downto 0) & not n_we; -- sample the INVERSE of n_we
			if selflag = '1' and we_sync = "0011" then
				flag_reg(to_integer(unsigned(abus(3 downto 1)))) <= abus(0);
			end if;
			
			-- Work on NMI generation
			if lrex = '1' then
				nmi_sync(0) <= '0';
			end if;
			iaq_sync <= iaq_sync(2 downto 0) & IAQ; 	-- sample IAQ
			if iaq_sync = "0011" then
				-- Let's see if this simple logic works. On each rising edge 
				-- of IAQ nmi_sync shift register advances.
				-- The bit shifted in is the pending lrex (actually it's inverse).
				nmi_sync <= nmi_sync(1 downto 0) & '1'; 
			end if;
			
			---------------------------------
			-- SPI interface
			---------------------------------
			if spi_state = '1' then
				spi_clk_div <= unsigned(spi_clk_div) + 1;
				if spi_clk_div = "011" then
					-- On next 50MHz clock the SPI clock becomes high, i.e. when the following
					-- asignments occur
					spi_shift_in <= spi_shift_in(6 downto 0) & SD_DO;
					spi_bit_count <= spi_bit_count + 1;
				end if;
				if spi_clk_div = "111" then
					spi_shift_out <= spi_shift_out(6 downto 0) & '1';
					if spi_bit_count = x"8" then
						-- Transfer is done! Yippee!
						spi_state <= '0';			-- No more busy
						spi_clk_div <= "000";	-- This may be redundant, but ensures SPI clock out is low.
					end if;
				end if;
			end if;
			
			-- Write to SPI port.
			if selspi = '1' and we_sync = "0011" and spi_state = '0' and abus(3 downto 0) = "0000" then
				spi_state <= '1';
				spi_clk_div <= "000";
				spi_bit_count <= (others => '0');
				spi_shift_out <= dbus(7 downto 0);
			end if;
			
			if selspi = '1' and we_sync = "0011" and abus(3 downto 0) = "0010" then
				-- setup chip select
				spi_cs <= dbus(0);
			end if;
			
		end if;
	end process;
	
	translated_addr <= 
		regs(to_integer(unsigned(abus(15 downto 12)))) when mapen = '1' and selmmu = '0'
		else "0000" & abus(15 downto 12);
	ra(18 downto 12) <= translated_addr(6 downto 0);
	
	debug <= std_logic_vector(spi_bit_count & '0' & spi_clk_div);
	
	dbus <=  
		regs(to_integer(unsigned(abus(3 downto 0)))) when n_DBIN = '0' and selmmu = '1'
		else spi_shift_in when n_DBIN = '0' and selspi = '1' and abus(3 downto 0) = "0000"
		-- spi status register
		else "000000" & spi_state & spi_cs when n_DBIN = '0' and selspi = '1' and abus(3 downto 0) = "0010"
		-- spi debug register
		else debug when n_DBIN = '0' and selspi = '1' and abus(3 downto 0) = "0100"
		else x"5A" when n_DBIN = '0' and seltest = '1'
		else "ZZZZZZZZ";
		
		tms9902_nCE <= '1' when real9902 = True  else n_CRU1_internal;
		n_CRU1 <=      '1' when real9902 = False else n_CRU1_internal;
		
pnr_tms9902 : tms9902 PORT MAP (
		CLK 	=> CLK50M,
		nRTS 	=> tms9902_rts_cts,  -- out
		nDSR  => '0', 					-- in
		nCTS  => tms9902_rts_cts,  -- in, driven by nRTS above
		nINT  => open, 				-- out
		nCE   => tms9902_nCE,		-- in
		CRUOUT => abus(0), 			-- in
		CRUIN  => CRUIN, 				-- out
		CRUCLK => CRUCLK, 		   -- in
		XOUT  => pnr9902_tx, 		-- out
		RIN   => pnr9902_rx, 		-- in
		S   	=> abus(5 downto 1)
	);		
  
end toplevel_architecture;
	
	
