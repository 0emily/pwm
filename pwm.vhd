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
--     09 Nov 26  Emily Wu
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
    constant startAddrSW1   : unsigned(18 downto 0) := to_unsigned(x"40000", 19);
    constant startAddrSW2   : unsigned(18 downto 0) := to_unsigned(x"48000", 19);
    constant startAddrSW3   : unsigned(18 downto 0) := to_unsigned(x"58000", 19);
    constant startAddrSW4   : unsigned(18 downto 0) := to_unsigned(x"7C000", 19);
    constant sampleMax: unsigned(11 downto 0) := to_unsigned(4095, 12);
    -- signals
    signal currAddr     : std_logic_vector(18 downto 0) := (others => '0');
    signal playing      : std_logic := '0';
    signal sample      :  unsigned(7 downto 0);
    signal activeSwitch : integer range 1 to 4 := 4;

    -- AddressCalc
    signal switchStates : std_logic_vector(4 downto 1) := (others => '0');
    signal messageEnded : std_logic;
    signal startAddr    : unsigned(18 downto 0);

    -- counters
    signal enSwitchCheck : std_logic := '0'; -- enable checking of switch inputs
    signal count12bit   : unsigned(11 downto 0);

begin
    countSample: process(clk)
    begin
        if rising_edge(clk) then
            count12bit <= count12bit + 1;
            if count12bit = sampleMax - 1 then
                enSwitchCheck <= '1';
            else enSwitchCheck <= '0';
            end if;
        end if;
    end process countSample;

-- ####################### Switches ############################################
-- Switch state related behavior
-- Special Behavior: when two switches are pressed simultaneously, the following
--      priority list is followed: SW4 > SW3 > SW2 > SW1
-- messageEnd indicates that the message just ended, stopping playing

    getSwitchStates: process(clk)
    begin
        if rising_edge(clk) then
            switchStates(4) <= SW4;
            switchStates(3) <= SW3;
            switchStates(2) <= SW2;
            switchStates(1) <= SW1;
        end if;
    end process getSwitchStates;

    -- set the starting address for this switch
    process(switchStates)
    begin
        if switchStates(4) = '1' then
            startAddr <= startAddrSW4;
        elsif switchStates(3) = '1' then
            startAddr <= startAddrSW3;
        elsif switchStates(2) = '1' then
            startAddr <= startAddrSW2;
        elsif switchStates(1) = '1' then
            startAddr <= startAddrSW1;
        end if;
    end process;

    -- check if the currently playing message has ended
    messageEnd: process(clk)
    begin
        if rising_edge(clk) then
            if (currAddr = to_unsigned(x"48000", 19)) or 
                (currAddr = to_unsigned(x"58000", 19))  or 
                (currAddr = to_unsigned(x"7C000", 19)) or 
                (currAddr = to_unsigned(x"80000", 19)) then
                    messageEnded <= '1';
            else messageEnded <= '0';
            end if;
        end if;
    end process messageEnd;

    -- switch activations; repeats; pipelining
    process(clk)
    begin
        if rising_edge(clk) then
            if enSwitchCheck = '1' then
                if playing = '0' then
                    if switchStates /= "0000" then
                        currAddr <= startAddr;

                        if switchStates(4) = '1' then
                                activeSwitch <= 4;
                            elsif switchStates(3) = '1' then
                                activeSwitch <= 3;
                            elsif switchStates(2) = '1' then
                                activeSwitch <= 2;
                            else
                                activeSwitch <= 1;
                            end if;

                        playing <= '1';
                    end if;

                elsif messageEnded = '1' then
                    if switchStates(activeSwitch) = '1' then
                        currAddr <= startAddr;
                    else playing <= '0';
                    end if;

                else --pipelining
                    sample <= unsigned(AudioData);
                    currAddr <= currAddr + 1;
                end if;
            end if;
        end if;
    end process; 


-- ###################### Comparator ###########################################
-- compares the 8 bit counter value to the data read from the EPROM
-- Special Behavior: Since the assignment did not specify what would happen when
-- the sample is equal to the counter, we have selected to set counter = 1 when
-- they are equal. 
    Comparator: process(clk)
    begin
        if rising_edge(clk) then
            if playing = '0' then
                AudioPWMOut <= '0';
            elsif count12bit(7 downto 0) > sample then
                AudioPWMOut <= '0';
            elsif (count12bit(7 downto 0) < sample) or 
                  (count12bit(7 downto 0) = sample) then
                AudioPWMOut <= '1';
            else
                null;
            end if;
        end if;
    end process Comparator;

    AudioAddr  <= currAddr;


end PWMSystemArchitecture; 
