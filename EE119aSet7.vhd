----------------------------------------------------------------------------
--
--  16-bit Adder/Subtracter for EE 119 Serial Divider Board
--
--  This file contains a design for taking input from the keypad and
--  displaying it on the 7-segment LEDs.  When the calculate button is
--  pressed, either the sum or difference of the two input 16-bit values is
--  computed (depending on the position of the Divisor switch).  The input
--  and displayed values are in hexadecimal.  For both input values only the
--  last 4 hex digits (16-bits) are used.
--
--  Revision History:
--     25 Nov 18  Glen George       Initial version (from 11/21/09 version
--                                     of addsub16.abl)
--     27 Nov 18  Glen George       Changed HaveKey logic to be flip-flop
--                                     based instead of an implied latch.
--     27 Nov 18  Glen George       Changed some constants to match Vivado
--                                     syntax.
--     25 Nov 20  Glen George       Changed DecoderBit to DecoderBits.
--     25 Nov 20  Glen George       Updated comments.
--
----------------------------------------------------------------------------



-- libraries
library  ieee;
use  ieee.std_logic_1164.all;
use  ieee.numeric_std.all;



--
--  AddSub16 entity declaration
--
--  The entity takes input from the keypad and displays it on the 7-segment
--  LEDs.  When the calculate button is pressed, either the sum or difference
--  of the two input 16-bit values is computed (depending on the position of
--  the Divisor switch).  The input values and sum/difference are displayed
--  in hexadecimal.  For both input values only the last 4 hex digits
--  (16-bits) are used.
--
--  Inputs:
--     nReset                  - active low reset signal (for testing only)
--                               tied high in hardware
--     nCalculate              - calculate the quotient (active low)
--     Divisor                 - input the divisor (not the dividend)
--     KeypadRdy               - there is a key available
--     Keypad(3 downto 0)      - keypad input
--     CLK                     - the clock (1 MHz)
--
--  Outputs:
--     HexDigit(3 downto 0)    - hex digit to display (to segment decoder)
--     DecoderEn               - enable for the 4:12 digit decoder
--     DecoderBits(3 downto 0) - digit to display (to 4:12 decoder)


entity  AddSub16  is

    port (
        nReset       :  in   std_logic;
        nCalculate   :  in   std_logic;
        Divisor      :  in   std_logic;
        KeypadRdy    :  in   std_logic;
        Keypad       :  in   std_logic_vector(3 downto 0);
        HexDigit     :  out  std_logic_vector(3 downto 0);
        DecoderEn    :  out  std_logic;
        DecoderBits  :  out  std_logic_vector(3 downto 0);
        CLK          :  in   std_logic
    );

end  AddSub16;


--
--  AddSub16 architecture
--

architecture  demo  of  AddSub16  is
    type states is (        --states the FSM can be in:
        idle,
        init,       -- clear remainder, set carry, op <= (-)
        run1,       -- shift remainder + dividend
        run2,       -- remainder <= remainder +- divisor
        run3,       -- shift C/!B into quotient, update op
        fixrem,     -- remainder <= remainder + divisor
        done        -- done active
        );
    -- keypad signals
    signal  HaveKey     :  std_logic;           -- have a key from the keypad
    signal  KeypadRdyS  :  std_logic_vector(2 downto 0); -- keypad ready synchronization

    -- LED multiplexing signals
    signal  MuxCntr  :  unsigned(9 downto 0);   -- multiplex counter (to
                                                --    divide 1 MHz to 1 KHz)
    signal  DigitClkEn  :  std_logic;           -- enable for the digit clock
    signal  CalcInEn    :  std_logic;           -- near end of a muxed digit
                                                --    (to enable calculations)
    signal  CurDigit  :  std_logic_vector(3 downto 0); -- current mux digit

    --  signals to select shift register operation
    --     ShiftOp = 0  ==>  hold
    --     ShiftOp = 1  ==>  calculate shift
    --     ShiftOp = 2  ==>  keypad input shift
    --     ShiftOp = 3  ==>  display shift
    signal    ShiftOp       :  std_logic_vector(1 downto 0);
    constant  ShiftOpHOLD   :  std_logic_vector(1 downto 0) := "00";
    constant  ShiftOpCALC   :  std_logic_vector(1 downto 0) := "01";
    constant  ShiftOpKEYIN  :  std_logic_vector(1 downto 0) := "10";
    constant  ShiftOpSHIFT  :  std_logic_vector(1 downto 0) := "11";

    --  12 stored hex digits (48 bits) in a shift register
    signal  DigitBits  :  std_logic_vector(47 downto 0);

    --  adder/subtracter signals
    signal  CalcResultBit  :  std_logic;        -- sum/difference output
    signal  CalcCarryOut   :  std_logic;        -- carry/borrow out
    signal  CarryFlag      :  std_logic;        -- stored carry flag


begin

    -- one-bit adder/subtracter (operation determined by Divisor input)
    -- adds/subtracts low bits of the operands (bits 0 and 16) generating
    --    CalcResultBit and CalcCarryOut
    CalcResultBit <= DigitBits(16) xor Divisor xor DigitBits(0) xor CarryFlag;
    CalcCarryOut  <= (DigitBits(0) and CarryFlag) or
                     ((DigitBits(16) xor Divisor) and DigitBits(0)) or
                     ((DigitBits(16) xor Divisor) and CarryFlag);

    -- carry flag needs to be stored for the next bit calculation
    process(CLK)
    begin

        if (rising_edge(CLK)) then

            -- initialize carry flag before each calculation starts (starts
            --    when MuxCntr = 1111100000 - so "before" is when bit 5 is 0)
            --    and initial value depends on whether adding or subtracting
            --    (determined by Divisor switch input)
            if (MuxCntr(5) = '0') then
                CarryFlag <= Divisor;
            end if;

            -- set carry flag to the carry out when calculating
            if (ShiftOp = ShiftOpCALC) then
                CarryFlag <= CalcCarryOut;
            end if;

            -- otherwise carry flag holds its value
        end if;

    end process;



    -- edge (and key) detection on KeypadRdy
    process(CLK)
    begin

        if rising_edge(CLK) then

            -- shift the keypad ready signal to synchronize and edge detect
            KeypadRdyS  <=  KeypadRdyS(1 downto 0) & KeypadRdy;

            -- have a key if have one already that hasn't been processed or a
            -- new one is coming in (rising edge of KeypadRdy), reset if on
            -- the last clock of Digit 3 or Digit 7 (depending on position of
            -- Divisor switch) and held otherwise
            if  (std_match(KeypadRdyS, "01-")) then
                -- set HaveKey on rising edge of synchronized KeypadRdy
                HaveKey <=  '1';
            elsif ((DigitClkEn = '1') and (CurDigit = "0011") and (Divisor = '0')) then
                -- reset HaveKey if on Dividend and at end of digit 3
                HaveKey <=  '0';
            elsif ((DigitClkEn = '1') and (CurDigit = "0111") and (Divisor = '1')) then
                -- reset HaveKey if on Divisor and at end of digit 7
                HaveKey <=  '0';
            else
                -- otherwise hold the value
                HaveKey <=  HaveKey;
            end if;

        end if;

    end process;



    -- counter for mux rate of approximately 1 KHz (1 MHz / 1024)
    process(CLK)
    begin

        -- count on the rising edge (clear on reset)
        if rising_edge(CLK) then
            if (nReset = '0') then
                MuxCntr <= (others => '0');
            else
                MuxCntr <= MuxCntr + 1;
            end if;
        end if;

    end process;


    -- the multiplex counter is also used for controlling the operation of
    -- the circuit - DigitClkEn signals the end of a multiplexed digit
    -- (MuxCntr = 3FF) and CalcInEn signals time periods in which calculations
    -- or inputting may be done (16 clocks - MuxCntr = 11111xxxx0)

    DigitClkEn  <=  '1'  when (MuxCntr = "1111111111")  else
                    '0';
    CalcInEn    <=  '1'  when (std_match(MuxCntr, "11111----0"))  else
                    '0';



    -- create the counter for output the current digit - order is 3, 2, 1, 0,
    --    7, 6, 5, 4, 11, 10, 9, then 8
    -- reset counter to 3, only increment if DigitClkEn is active
    process (CLK)
    begin

        if (rising_edge(CLK)) then

            -- reset the decoder to 3 on reset
            if (nReset = '0') then
                CurDigit <= "0011";

            -- create the appropriate count sequence
            elsif (DigitClkEn = '1') then
                CurDigit(0) <= not CurDigit(0);
                CurDigit(1) <= CurDigit(1) xor not CurDigit(0);
                if (std_match(CurDigit, "0-00")) then
                    CurDigit(2) <= not CurDigit(2);
                end if;
                if (std_match(CurDigit, "-100") or std_match(CurDigit, "1-00")) then
                    CurDigit(3) <= not CurDigit(3);
                end if;

            -- otherwise hold the current value
            else
                CurDigit <= CurDigit;

            end if;
        end if;

    end process;


    -- always enable the digit decoder
    DecoderEn  <=  '1';

    -- output the current digit to the digit decoder
    DecoderBits  <=  CurDigit;


    -- the hex digit to output is just the low nibble of the shift register
    HexDigit  <=  DigitBits(3 downto 0);



    -- shift register commands
    --    set bit 0 if shifting for display or doing a calculation
    --    set bit 1 if shifting for display or inputting a key (MuxCntr = 3F6)
    ShiftOp  <=  ShiftOpSHIFT  when (DigitClkEn = '1')  else
                 ShiftOpKEYIN  when ((CalcInEn = '1') and
                                     (nCalculate = '1') and
                                     (HaveKey = '1') and
                                     (std_match(MuxCntr, "-----1011-") and
                                      (((CurDigit = "0011") and (Divisor = '0')) or
                                       ((CurDigit = "0111") and (Divisor = '1')))))  else
                 ShiftOpCALC   when ((CalcInEn = '1') and
                                     (nCalculate = '0') and
                                     (CurDigit = "0011"))  else
                 ShiftOpHOLD;



    -- the shift register
    --    bits 15-0    first operand
    --    bits 31-16   second operand
    --    bits 47-32   result
    -- operations
    --    ShiftHold:    DigitBits(47..0) = DigitBits(47..0)
    --    ShiftCalc:    DigitBits(47..0) = CalcResultBit | DigitBits(47..1)
    --    ShiftKeyIn:   DigitBits(47..0) = DigitBits(47..16) |
    --                                     DigitBits(11..0) | Keypad(3..0)
    --    ShiftDisplay: DigitBits(47..0) = DigitBits(3..0) | DigitBits(47..4)
    process(CLK)
    begin

        -- shift on the rising edge
        if rising_edge(CLK) then
            case  ShiftOp  is
                when ShiftOpHOLD =>
                    DigitBits <= DigitBits;
                when ShiftOpCALC =>
                    DigitBits <= CalcResultBit & DigitBits(47 downto 1);
                when ShiftOpKEYIN =>
                    DigitBits <= DigitBits(47 downto 16) &
                                 DigitBits(11 downto 0) & Keypad;
                when ShiftOpSHIFT =>
                    DigitBits <= DigitBits(3 downto 0) & DigitBits(47 downto 4);
            end case;
        end if;

    end process;


end  demo;
