-- toplevel.vhd
-- TMS9995 project for Mini Spartan 6 board with FTDI UART
-- XC6SLX9-2TQG144
--
-- toplevel.vhd
--
-- Started 2016-03-23 (C) Erik Piehl
--


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
--use IEEE.STD_LOGIC_ARITH.ALL;
--use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.numeric_std.all;


library UNISIM;
use UNISIM.vcomponents.all; -- get xilinx ram

entity toplevel is
	generic (
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
	CRUCLK		: out std_logic;
	n_CRU1		: out std_logic;
	n_CRU2		: out std_logic;
	
	n_MEMEN		: in std_logic;
	n_WE			: in std_logic;
	n_DBIN		: in std_logic;
	ABUS			: in std_logic_vector(15 downto 0);
	DBUS			: inout std_logic_vector(7 downto 0);

-- UART routing to FTDI chip
   RX02			: out std_logic;
	TX02			: in  std_logic;
	
-- NMI signals to enable single stepping
	n_NMI			: out std_logic;
	IAQ			: in std_logic;

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

	signal reset 		  	: std_logic;
	signal reset_delay  	: std_logic_vector(7 downto 0) := x"00";
	signal protect 		: std_logic;
	signal mapen			: std_logic;
	signal n_romen			: std_logic;
	signal selmmu        : std_logic := '0';
	signal seltest       : std_logic := '0';
	signal selflag       : std_logic := '0';
	signal n_romce1		: std_logic;
	signal ckon				: std_logic;
	signal ckoff			: std_logic;
	signal lrex				: std_logic;
	signal lrex_latched  : std_logic := '0';	-- lrex is pending
	
	signal nmi_sync		: std_logic_vector(2 downto 0);
	signal iaq_sync		: std_logic_vector(3 downto 0);	-- Delay line to find rising edges of IAQ
	
	-- flag_reg:
	--		bit 0 : n_romen - when zero, the first 32K of ROM overlay bottom 32K of address space
	--		bit 1 : mapen - when one, the MMU is enabled
	signal flag_reg 		: std_logic_vector(7 downto 0);

	type abank is array (natural range 0 to (2**aregs)-1) of std_logic_vector(awidth-1 downto 0);
	signal regs   : abank;
	signal translated_addr : std_logic_vector(awidth-1 downto 0);

	signal we_sync		: std_logic_vector(3 downto 0);	-- Delay line to sample and synchronize n_WE/n_CRUCLK 
	
begin
	TX <= TX02;
	RX02 <= RX;
	
	LED(0) <= not TX02;
	LED(1) <= not RX;
	LED(2) <= SW1;
	LED(3) <= SW2;
	LED(7 DOWNTO 4) <= flag_reg(3 downto 0);
	
	-- External instruction decoding
   cruclk      <= '1' when n_memen = '1' and n_we = '0' and dbus(7 downto 5) = "000" else '0';
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
   n_cru1      <= '0' when n_memen = '1' and abus(15 downto 6) = sel9902(15 downto 6) else '1';
   n_cru2      <= '0' when n_memen = '1' and abus(15 downto 6) = sel9901(15 downto 6) else '1';
	
	mapen <= flag_reg(1);
	n_romen <= flag_reg(0);
	
	-- NMI output
	n_NMI <= nmi_sync(2);
   
	-- Memory mapped peripherals inside FPGA
   -- selmmu is high when the FPGA's MMU is being accessed
   selmmu <= '1'  when abus(15 downto 4) = mmubase(15 downto 4) and n_memen = '0' else '0';
	seltest <= '1' when abus(15 downto 4) = testbas(15 downto 4) and n_memen = '0' else '0';
	-- CRU peripherals inside the FPGA
	selflag <= '1' when abus(15 downto 4) = flagbas(15 downto 4) and n_memen = '1' else '0'; 
	
  -- put the MMU design here.
	process (CLK50M, SW1)
	begin
		if SW1 = '1' then
			-- Process reset here.
			n_reset_out <= '0';
			ready <= '0';
			reset_delay <= x"00";
			flag_reg <= x"00";
			we_sync <= (others => '0');
			nmi_sync <= (others => '1');
			iaq_sync <= (others => '0');
			lrex_latched <= '0';
		elsif rising_edge(CLK50M) then
			-- take care of reset, enable zero wait states
			n_reset_out <= reset_delay(7); -- this does not work: reset'length-1
			ready 		<= reset_delay(5);
			reset_delay <= reset_delay(6 downto 0) & '1';
		
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
				-- lrex_latched <= '1';	-- Make lrex pending
				nmi_sync(0) <= '0';
			end if;
			iaq_sync <= iaq_sync(2 downto 0) & IAQ; 	-- sample IAQ
			if iaq_sync = "0011" then
				-- Let's see if this simple logic works. On each rising edge 
				-- of IAQ nmi_sync shift register advances.
				-- The bit shifted in is the pending lrex (actually it's inverse).
				nmi_sync <= nmi_sync(1 downto 0) & '1'; -- not lrex_latched;
				-- lrex_latched <= '0';
			end if;
			
		end if;
	end process;
	
	translated_addr <= 
		regs(to_integer(unsigned(abus(15 downto 12)))) when mapen = '1' and selmmu = '0'
		else "0000" & abus(15 downto 12);
	ra(18 downto 12) <= translated_addr(6 downto 0);
	dbus <=  
		regs(to_integer(unsigned(abus(3 downto 0)))) when n_DBIN = '0' and selmmu = '1'
		else x"5A" when n_DBIN = '0' and seltest = '1'
		else "ZZZZZZZZ";
  
end toplevel_architecture;
	
	
