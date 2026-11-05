----------------------------------------------------------------------------------
-- ULA.vhd  -  4-bit ALU, everything in ONE file.
-- Top-level entity to select in ISE:  ula_top
--
-- HOW TO USE (one push-button = "next step"; the board has only 8 LEDs):
--   LEDs, left to right:   LED7 LED6 LED5 LED4 | LED3 LED2 LED1 LED0
--   while entering data:    1    1   step step |  the switches, live
--   in the result state:    Z    N    C    V   |  the 4-bit result
--
--   step 0) set the OPERATION on the switches        LED7..4 = 1 1 0 0   -> press button
--   step 1) set the first operand A on the switches  LED7..4 = 1 1 0 1   -> press button
--   step 2) set the second operand B                 LED7..4 = 1 1 1 0   -> press button
--   step 3) RESULT is shown: LED7..4 are the flags Z N C V              -> press button -> step 0
--   (Z and N can never be on together, so "LED7 and LED6 both on" can only mean
--    "you are entering data" - it can never be confused with a result.)
--
-- OPERATIONS (opcode = vetor(2 downto 0); vetor(3) is ignored when choosing)
--   000  ADD      A + B   (two's complement)
--   001  SUB      A - B   (A + not B + 1)
--   010  SHL      A shifted left 1 (0101 -> 1010)
--   011  COMPARE  A vs B (unsigned)  display: bit2 = A>B, bit1 = A=B, bit0 = A<B
--   100  INC      A + 1
--   101  DEC      A - 1
--   110  NOT      not A (inverter)
--   111  XOR      A xor B
--   (INC, DEC, SHL, NOT only use A; B is still asked for but ignored.)
--
-- FLAGS (shown in the result state, one LED each: LED7=Z, LED6=N, LED5=C, LED4=V):
--   Z (flag_Z): result = 0000                     (all operations)
--   N (flag_N): result(3) = 1, i.e. negative      (ADD, SUB, INC, DEC only)
--   C (Cout)  : carry out of the adder            (ADD, SUB, INC, DEC)
--               SUB/DEC: C = 1 means NO borrow (A >= B unsigned)
--               SHL: C = the bit shifted out (A(3))
--   V (flag_V): signed overflow                   (ADD, SUB, INC, DEC only)
--   COMPARE, NOT and XOR can only ever set Z.
--
-- PINS: ISE needs these in a separate .ucf file (see Pinos.ucf). Copy for reference:
--   clk_50MHz E12 | vetor[0..3] V8 U10 U8 T9 | botao T16 (BTN_EAST) | reset T15 (BTN_SOUTH)
--   display_leds[0..3] = LED0..3 = R20 T19 U20 U19
--   Cout = LED5 V20 (carry) | flag_V = LED4 V19 | flag_N = LED6 Y22 | flag_Z = LED7 W21
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

----------------------------------------------------------------------------------
-- 1) DEBOUNCE: cleans the button and gives ONE 1-clock-cycle pulse per press.
----------------------------------------------------------------------------------
entity debounce is
    generic (
        CLK_FREQ    : positive := 50_000_000;  -- board clock (Hz)
        DEBOUNCE_MS : positive := 10           -- button must be stable this long
    );
    port (
        clk    : in  STD_LOGIC;
        btn_in : in  STD_LOGIC;   -- raw button
        pulso  : out STD_LOGIC    -- 1 clock cycle high per press
    );
end debounce;

architecture Behavioral of debounce is
    constant LIMITE : integer := (CLK_FREQ / 1000) * DEBOUNCE_MS;
    signal sync      : STD_LOGIC_VECTOR(1 downto 0) := "00"; -- 2 FFs (avoid metastability)
    signal estavel   : STD_LOGIC := '0';                     -- accepted (clean) button level
    signal estavel_d : STD_LOGIC := '0';                     -- same, 1 clock later
    signal cont      : integer range 0 to LIMITE := 0;
begin
    process (clk)
    begin
        if rising_edge(clk) then
            sync <= sync(0) & btn_in;
            if sync(1) /= estavel then              -- input disagrees with accepted level
                if cont = LIMITE - 1 then           -- ...for long enough: accept it
                    estavel <= sync(1);
                    cont    <= 0;
                else
                    cont <= cont + 1;
                end if;
            else
                cont <= 0;                          -- bounce: start counting again
            end if;
            estavel_d <= estavel;
        end if;
    end process;

    pulso <= estavel and not estavel_d;             -- rising edge = one pulse per press
end Behavioral;

----------------------------------------------------------------------------------
-- 2) ALU: purely combinational. op selects what to compute from A and B.
--    resultado = 4-bit result; flag_c/v/n/z = carry, overflow, negative, zero.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity alu4 is
    port (
        op        : in  STD_LOGIC_VECTOR (2 downto 0);
        A         : in  STD_LOGIC_VECTOR (3 downto 0);
        B         : in  STD_LOGIC_VECTOR (3 downto 0);
        resultado : out STD_LOGIC_VECTOR (3 downto 0);
        flag_c    : out STD_LOGIC;    -- carry out
        flag_v    : out STD_LOGIC;    -- signed overflow
        flag_n    : out STD_LOGIC;    -- negative
        flag_z    : out STD_LOGIC     -- zero
    );
end alu4;

architecture Behavioral of alu4 is
    signal B_eff  : STD_LOGIC_VECTOR (3 downto 0);   -- what the adder adds to A
    signal cin_b  : STD_LOGIC;                       -- adder carry-in
    signal cin_v  : UNSIGNED (4 downto 0);
    signal soma   : UNSIGNED (4 downto 0);           -- 5 bits: 4 result + carry
    signal ovf    : STD_LOGIC;
    signal aritm  : STD_LOGIC;                       -- '1' for ADD/SUB/INC/DEC
    signal res_i  : STD_LOGIC_VECTOR (3 downto 0);
    signal c_i    : STD_LOGIC;
begin
    -- ONE adder does ADD, SUB, INC and DEC, by choosing what is added to A:
    --   ADD: A + B        + 0        SUB: A + (not B) + 1
    --   INC: A + 0000     + 1        DEC: A + 1111    + 0   (1111 = -1)
    with op select
        B_eff <= B      when "000",
                 not B  when "001",
                 "0000" when "100",
                 "1111" when "101",
                 "0000" when others;
    cin_b <= '1' when (op = "001" or op = "100") else '0';
    cin_v <= "0000" & cin_b;
    soma  <= unsigned('0' & A) + unsigned('0' & B_eff) + cin_v;

    aritm <= '1' when (op = "000" or op = "001" or op = "100" or op = "101") else '0';

    -- signed overflow: A and the added value have the same sign,
    -- but the result has a different sign
    ovf <= (A(3) xnor B_eff(3)) and (A(3) xor soma(3));

    process (op, A, B, soma)
    begin
        res_i <= "0000";          -- defaults so no latches are created
        c_i   <= '0';
        case op is
            when "000" | "001" | "100" | "101" =>      -- ADD / SUB / INC / DEC
                res_i <= std_logic_vector(soma(3 downto 0));
                c_i   <= soma(4);

            when "010" =>                              -- shift left by 1
                res_i <= A(2 downto 0) & '0';
                c_i   <= A(3);

            when "011" =>                              -- comparator (unsigned)
                if unsigned(A) > unsigned(B) then
                    res_i <= "0100";
                elsif A = B then
                    res_i <= "0010";
                else
                    res_i <= "0001";
                end if;

            when "110" =>                              -- inverter
                res_i <= not A;

            when "111" =>                              -- XOR
                res_i <= A xor B;

            when others => null;
        end case;
    end process;

    resultado <= res_i;
    flag_c    <= c_i;
    flag_v    <= ovf and aritm;
    flag_n    <= res_i(3) and aritm;
    flag_z    <= '1' when res_i = "0000" else '0';
end Behavioral;

----------------------------------------------------------------------------------
-- 3) TOP LEVEL: state machine + registers.  ONE clock (50 MHz) for everything.
--    The button is not a clock: it only produces an "advance" pulse.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity ula_top is
    generic (
        CLK_FREQ    : positive := 50_000_000;   -- only changed in simulation
        DEBOUNCE_MS : positive := 10
    );
    port (
        clk_50MHz    : in  STD_LOGIC;
        vetor        : in  STD_LOGIC_VECTOR (3 downto 0);  -- switches
        botao        : in  STD_LOGIC;                      -- the "next" button
        reset        : in  STD_LOGIC;
        display_leds : out STD_LOGIC_VECTOR (3 downto 0);
        -- upper LEDs: flags in the result state, "entering data" code otherwise
        Cout         : out STD_LOGIC;     -- LED5 (flag C)
        flag_Z       : out STD_LOGIC;     -- LED7
        flag_N       : out STD_LOGIC;     -- LED6
        flag_V       : out STD_LOGIC      -- LED4
    );
end ula_top;

architecture Behavioral of ula_top is
    component debounce is
        generic (CLK_FREQ : positive; DEBOUNCE_MS : positive);
        port (clk : in STD_LOGIC; btn_in : in STD_LOGIC; pulso : out STD_LOGIC);
    end component;

    component alu4 is
        port (op        : in  STD_LOGIC_VECTOR (2 downto 0);
              A         : in  STD_LOGIC_VECTOR (3 downto 0);
              B         : in  STD_LOGIC_VECTOR (3 downto 0);
              resultado : out STD_LOGIC_VECTOR (3 downto 0);
              flag_c    : out STD_LOGIC;
              flag_v    : out STD_LOGIC;
              flag_n    : out STD_LOGIC;
              flag_z    : out STD_LOGIC);
    end component;

    type estado_t is (SEL_OP, LOAD_A, LOAD_B, SHOW);
    signal estado   : estado_t := SEL_OP;

    signal pulso    : STD_LOGIC;
    signal rst_sync : STD_LOGIC_VECTOR (1 downto 0) := "00";
    signal op       : STD_LOGIC_VECTOR (2 downto 0) := (others => '0');
    signal A, B     : STD_LOGIC_VECTOR (3 downto 0) := (others => '0');
    signal res      : STD_LOGIC_VECTOR (3 downto 0);
    signal fc, fv, fn, fz : STD_LOGIC;
begin
    u_deb : debounce
        generic map (CLK_FREQ => CLK_FREQ, DEBOUNCE_MS => DEBOUNCE_MS)
        port map (clk => clk_50MHz, btn_in => botao, pulso => pulso);

    u_alu : alu4
        port map (op => op, A => A, B => B, resultado => res,
                  flag_c => fc, flag_v => fv, flag_n => fn, flag_z => fz);

    -- Sequential part: the ONLY clocked process of the top level
    process (clk_50MHz)
    begin
        if rising_edge(clk_50MHz) then
            rst_sync <= rst_sync(0) & reset;

            if rst_sync(1) = '1' then
                estado <= SEL_OP;
                op <= (others => '0');
                A  <= (others => '0');
                B  <= (others => '0');
            elsif pulso = '1' then                     -- one button press
                case estado is
                    when SEL_OP => op <= vetor(2 downto 0); estado <= LOAD_A;
                    when LOAD_A => A  <= vetor;             estado <= LOAD_B;
                    when LOAD_B => B  <= vetor;             estado <= SHOW;
                    when SHOW   =>                          estado <= SEL_OP;
                end case;
            end if;
        end if;
    end process;

    -- Output part: combinational, depends only on the current state.
    -- Upper LEDs (Z N C V = LED7 LED6 LED5 LED4):
    --   entering data -> Z=1, N=1 (a combination no result can produce) and
    --                    C,V = step number: 00 operation, 01 A, 10 B
    --   result        -> the real flags
    process (estado, vetor, res, fc, fv, fn, fz)
    begin
        display_leds <= vetor;          -- while entering data: show the switches
        flag_Z <= '1'; flag_N <= '1'; Cout <= '0'; flag_V <= '0';   -- step 0: 1100
        case estado is
            when SEL_OP => null;                                    -- 1100
            when LOAD_A => flag_V <= '1';                           -- 1101
            when LOAD_B => Cout   <= '1';                           -- 1110
            when SHOW   =>
                display_leds <= res;
                flag_Z <= fz; flag_N <= fn; Cout <= fc; flag_V <= fv;
        end case;
    end process;
end Behavioral;
