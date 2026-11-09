--------------------------------------------------------------------------------
--
--  PWM Sound in VHDL
--
--  This is an implementation of a ___ in VHDL
--  It uses a ___ type architecture. 
--
--  Entities included are:
--     comparator      - compares current counter8bit value with EPROM sample
--     counter8bit     - 8 bit counter [0 to 255] - within each pwm pulse
--     counter4bit     - 4 bit counter [0 to 15] - num pwm pulses in 1 sample
--     counter20bit    - 20 bit counter [0 to 1,048,575] - num samples/addresses
--     readEPROM       - reads data fom EPROM; pipelined structure
--  Revision History:
--     06 Nov 26  Emily Wu          Initial Revision
--     07 Nov 26  Emily Wu          Merged into 1 entity; changed inputs/outputs
--     09 Nov 26  Emily Wu          Fixed compile errors, switch/address table,
--                                  added pipelined sample latch
--
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- #############################################################################
-- PWMSystem entity definition

entity PWMSystem is port(
    clk             :   in  std_logic;
    SW1             :   in  std_logic;
    SW2             :   in  std_logic;
    SW3             :   in  std_logic;
    SW4             :   in  std_logic;
    AudioData       :   in  std_logic_vector(7 downto 0);
    AudioAddr       :   out std_logic_vector(18 downto 0);
    AudioPWMOut     :   out std_logic
    );
end PWMSystem;

--
-- PWMSystem behavioral architecture
--

architecture PWMSystemArchitecture of PWMSystem is
    -- constants
    -- CHANGED: now unsigned(19 downto 0) so they match startAddr (a 5-digit hex
    --          literal is 20 bits, it can't go in a 19 bit vector)
    -- CHANGED: SW1 <-> SW4 and SW2 <-> SW3 were swapped; the table says
    --          SW4 = message 1 (0x40000) ... SW1 = message 4 (0x7C000)
    constant startAddrSW1 : unsigned(19 downto 0) := x"7C000";
    constant startAddrSW2 : unsigned(19 downto 0) := x"58000";
    constant startAddrSW3 : unsigned(19 downto 0) := x"48000";
    constant startAddrSW4 : unsigned(19 downto 0) := x"40000";
    -- NEW: one PAST the last sample of each message (replaces the x"47FFF" etc.
    --      compares, see messageEnd below)
    constant endAddrSW1   : unsigned(19 downto 0) := x"80000";
    constant endAddrSW2   : unsigned(19 downto 0) := x"7C000";
    constant endAddrSW3   : unsigned(19 downto 0) := x"58000";
    constant endAddrSW4   : unsigned(19 downto 0) := x"48000";
    -- signals
    signal finished     : std_logic := '0';
    signal reset        : std_logic;
    signal currAddr     : std_logic_vector(18 downto 0) := (others => '0');
    signal playing      : std_logic := '0';
    signal sample       : std_logic_vector(7 downto 0) := (others => '0');  -- NEW

    -- AddressCalc
    signal SW           : std_logic_vector(4 downto 1) := (others => '0');  -- NEW
    signal switchStates : std_logic_vector(4 downto 1) := (others => '0');
    signal messageEnd   : std_logic;
    signal startAddr    : unsigned(19 downto 0);
    signal endAddr      : unsigned(19 downto 0);                            -- NEW

    -- counters
    signal enable4      : std_logic;
    signal enable8      : std_logic;
    signal enable20     : std_logic;
    signal count4bit    : std_logic_vector(3 downto 0);
    signal count8bit    : std_logic_vector(7 downto 0);
    signal count20bit   : std_logic_vector(19 downto 0);
    signal count_tracker4 : unsigned(3 downto 0);
    signal count_tracker8 : unsigned(7 downto 0);
    signal count_tracker20 : unsigned(19 downto 0);

begin

-- ####################### AddressCalc #########################################
-- Calculating the current address
-- Special Behavior: when two switches are pressed simultaneously, the following
--      priority list is followed: SW4 > SW3 > SW2 > SW1
-- messageEnd indicates that the message just ended, stopping playing
-- finished has a 1 cycle delay, determining if the same sound should play again
--      (if the OG switch is still being held)

-- CHANGED: the end is now the address one PAST the last sample, looked up for
-- the message that is playing, and only checked on the last clock of a sample
-- period (enable20). Before, it fired the moment the last address came out and
-- cut the last sample short (and 0x7C000 is both the end of message 3 and the
-- start of message 4, so it has to be per-message).
endAddr <= endAddrSW4 when switchStates(4) = '1' else
           endAddrSW3 when switchStates(3) = '1' else
           endAddrSW2 when switchStates(2) = '1' else
           endAddrSW1;

messageEnd <= '1' when enable20 = '1' and
                       unsigned(currAddr) = resize(endAddr, 19)
              else '0';

startAddr <= startAddrSW4 when switchStates(4) = '1' else
            startAddrSW3 when switchStates(3) = '1' else
            startAddrSW2 when switchStates(2) = '1' else
            startAddrSW1;

-- NEW: counters are held at 0 whenever nothing is playing, so every message
-- starts on a clean sample boundary (the comparator no longer drives this)
reset <= not playing;

    AddressCalc: process(clk)
    begin
        if rising_edge(clk) then
        SW <= SW4 & SW3 & SW2 & SW1;    -- NEW: register the switches (sync)
        finished <= messageEnd;

        if messageEnd = '1' then
            playing <= '0';
            currAddr <= (others => '0');

        elsif finished = '1' then
            -- restart only if the OG switch is still pressed
            -- CHANGED: switchStates now holds only the selected switch, so
            -- other switches being pressed/released doesn't matter
            if (SW and switchStates) /= "0000" then
                playing <= '1';
            end if;

        elsif playing = '0' then
            if SW /= "0000" then
                -- CHANGED: remember only the highest priority switch pressed
                if    SW(4) = '1' then switchStates <= "1000";
                elsif SW(3) = '1' then switchStates <= "0100";
                elsif SW(2) = '1' then switchStates <= "0010";
                else                   switchStates <= "0001";
                end if;
                playing <= '1';
            end if;

        else
            -- CHANGED: resize to the 19 bit address
            currAddr <= std_logic_vector(resize(startAddr + unsigned(count20bit), 19));
        end if;
    end if;
    end process AddressCalc;

-- ###################### ReadEPROM ############################################
-- NEW: pipelining. The address has been stable for a whole sample period by the
-- time enable20 hits, so latch the EPROM byte then (the address moves on one
-- clock later) and play the latched byte, not AudioData, during the next sample
-- The first sample period of a message is silent (nothing latched yet)
    ReadEPROM: process(clk)
    begin
        if rising_edge(clk) then
            if playing = '0' then
                sample <= (others => '0');
            elsif enable20 = '1' then
                sample <= AudioData;
            end if;
        end if;
    end process ReadEPROM;

-- ###################### Comparator ###########################################
-- compares the 8 bit counter value to the sample latched from the EPROM
-- Special Behavior: Since the assignment did not specify what would happen when
-- the sample is equal to the counter, we have selected to set counter = 0 when
-- they are equal. 
-- CHANGED: clocked (glitch free output), uses sample instead of AudioData,
-- output is 0 when not playing, and equal -> 0 so a pulse is exactly "sample"
-- clocks wide (and sample = 0 is true silence)
    Comparator: process(clk)
    begin
        if rising_edge(clk) then
            if playing = '0' then
                AudioPWMOut <= '0';
            elsif unsigned(count8bit) < unsigned(sample) then
                AudioPWMOut <= '1';
            else
                AudioPWMOut <= '0';
            end if;
        end if;
    end process Comparator;

-- ###################### Counter 4 bit ########################################
--  tracking the current pulse number within each sample (synchronous)
    counter4bit: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                count_tracker4 <= (others => '0');    -- reset counter to 0
            elsif enable4 = '1' then
                count_tracker4 <= count_tracker4 + 1;  -- increment counter
            end if;
        end if;
    end process counter4bit;

    -- change the type to std_logic vector, matching expected output
    count4bit <= std_logic_vector(count_tracker4);

    -- CHANGED: concurrent "when/else" (an if can't sit outside a process), and
    -- gated with enable4 so it is high for ONE clock, not the whole 16th pulse
    enable20 <= '1' when count4bit = x"F" and enable4 = '1' else '0';

-- ###################### Counter 8 bit ########################################
-- counts from 0 to 255 iwthin each PWM pulse
    counter8bit: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                count_tracker8 <= (others => '0');        -- reset counter to 0
            elsif enable8 = '1' then
                count_tracker8 <= count_tracker8 + 1;      -- increment counter
            end if;
        end if;
    end process counter8bit;

    -- change the type to std_logic vector, matching expected output
    count8bit <= std_logic_vector(count_tracker8);

    enable8 <= '1';     -- NEW: was never driven; the 8 bit counter always runs

    enable4 <= '1' when count8bit = x"FF" else '0';

-- ###################### Counter 20 bit #######################################
-- tracks the current address 
    counter20bit: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                count_tracker20 <= (others => '0');    -- reset counter to 0
            elsif enable20 = '1' then
                count_tracker20 <= count_tracker20 + 1;  -- increment counter
            end if;
        end if;
    end process counter20bit;

    -- change the type to std_logic vector, matching expected output
    count20bit <= std_logic_vector(count_tracker20);

    -- CHANGED: was a process with no "begin"; it's just a wire
    AudioAddr  <= currAddr;

end PWMSystemArchitecture;
