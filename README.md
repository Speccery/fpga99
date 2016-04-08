# fpga99

Imported to github by Erik Piehl (C) 2016-04-04.
This work is licensed under LGPL, please see the LICENSE file.

This is very much work in progress. Please also checkout the wiki as I've started to put information in there, including some pictures.

This is an FPGA design project for my TMS9995 breadboard project. It is a VHDL design, done in ISE 14.7 from Xilinx. The free version of the Xilinx tool suite is sufficient for synthesis; it's what I used.

I started to discuss the board under my alias "speccy" in Vintage computer forums.
http://www.vcfed.org/forum/showthread.php?15580-Powertran-Cortex/page88

The design is based on Stuart Conner's TMS9995 computer, featured on his web site:
http://www.avjd51.dsl.pipex.com/tms9995_breadboard/tms9995_breadboard.htm

But instead of being a discrete logic implementation, here all glue logic and other functionality is contained in the FPGA.

Below is what I wrote there, with some edits:

Basically my board can be summarized now as TMS9995 meets Xilinx Spartan 6 FPGA, picture below. The nice thing about working with breadboard computers is that it is so easy to modify them. So I started my version (indeed before being aware of this thread and the cortex mini board) by basically hooking up TMS9995, FLASH ROM, TMS9901 parallel interface and a GAL22V10 to do address decoding, while waiting for a bunch of TMS9902 UARTs to arrive from china. Since with the chips I got I could quite replicate Stuart's original design, I just ended up writing some TMS9900 assembly code to test the board and got LEDs blinking with the TMS9901. When the UARTs did arrive (a month from order - I ordered them before starting the build) I then decided to first test the UART before wiring up the SRAM. Luckily the TMS9902 chips I got turned out to be in working order, so I was able to communicate with the TMS9995 and finally fulfill the blank in my childhood of not being able to write assembly code for my TI99/4A - I was a bit too young to realize I should have bought mini memory card bridgerather than extended basic...

Well to come back to this story, I got Stuart's design to work and tested things a little. I noticed that to my surprise the old TI chips would run at surprisingly low voltages. From by bench power supply I was able to go to as low 3.4V before the breadboard stopped working. I was amazed, but I also realized I could directly hook up 3.3V chips without frying them. This is the point in time I reached out to Stuart, and got the pointer to this thread. He kindly also posted me the schematics of the Cortex mini. I started to think that this would be the perfect opportunity to implement a strange version of the cortex mini. So I removed the GAL chip, hooked one of my FPGA boards to the GAL's pins and reimplemented the address decoding logic in the FPGA. That all worked. Encouraged by that, I proceeded to implement more logic into the FPGA. I have not gone very far yet on that path, but most of the logic on the cortex mini is now working in this implementation; namely I wrote an implementation of something like the 64LS612 in VHDL while trying to keep this compatible with the cortex mini. 

To summarize, my board contains the following chips:
* TMS9995 
* 256K FLASH (Pmc29F002T)
* 512K SRAM 
* TMS9901 GPIO and interrupt controller
* TMS9902 UART

The FPGA implements a reset circuit, the MMU (similar to 74LS612), the "flags" register in the cortex mini (the two blue less on the FPGA board indicate that ROM overlay is turned off and MMU paging is turned on), and an NMI generator to enable code single stepping.

