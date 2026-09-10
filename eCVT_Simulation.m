%% eCVT System MATLAB Simulation
% Hardware-out-of-loop (HooL) test for Knight Racing Baja SAE eCVT.
% Replicates all firmware logic from ECVT_Latest.ino (Teensy 4.1).
%
% USAGE:
%   Run the script as-is for the default scenario (RPM ramp + preset switch).
%   Edit the SCENARIO CONFIGURATION section below to test different conditions.
%   Enable FAULT INJECTION to validate fault detection before hardware is available.
%
% Requires: MATLAB R2016b or later.

clear; clc; close all;

fprintf('=======================================================\n');
fprintf('  eCVT System Simulation  —  Knight Racing Baja SAE\n');
fprintf('  Mirroring: ECVT_Latest.ino  (Teensy 4.1)\n');
fprintf('=======================================================\n\n');

%% ============================================================
%%  FIRMWARE CONSTANTS  ← must match ECVT_Latest.ino exactly
%% ============================================================
MAGNETS_PER_REV        = 1;
RPM_TIMEOUT_US         = 1e6;          % 1 second [us]
RELAY_DEADTIME_MS      = 75;           % min ms between direction changes
PRINT_INTERVAL_MS      = 50;           % telemetry cadence [ms]
ACT_DEADBAND           = 50;           % position deadband [ADC counts]
ACT_POS_MIN            = 100;          % software lower clamp [counts]
ACT_POS_MAX            = 2800;         % software upper clamp [counts]
ACT_FEEDBACK_MIN       = 10;           % wire-break detection threshold
ACT_FEEDBACK_MAX       = 3000;         % short-circuit detection threshold
RPM_MIN_CONTROL        = 1800.0;       % CVT engagement RPM floor
RPM_MAX_VALID          = 4050.0;       % implausible RPM ceiling
EMA_ALPHA              = 0.15;         % position EMA smoothing factor
ACT_STALL_TIMEOUT_MS   = 5000;         % stall detection window [ms]
ACT_MAX_RATE_PER_CYCLE = 150;          % max ADC change per 50 ms cycle
ACT_RATE_CHECK_MS      = 50;           % rate-of-change check interval [ms]
ENGINE_HP              = 10.0;         % Briggs & Stratton 10 HP
RPM_AVG_SAMPLES        = 4;            % hall pulse rolling-average depth
BTN_DEBOUNCE_MS        = 200;          % mode button debounce [ms]

%% ============================================================
%%  PRESET CURVES  ← must match firmware const structs
%% ============================================================
RPM_BP = [1800, 2150, 2500, 2850, 3200, 3550, 3900];  % RPM breakpoints

PRESETS(1).name      = 'Economy';
PRESETS(1).positions = [400,  700, 1000, 1350, 1700, 2050, 2400];

PRESETS(2).name      = 'Sport';
PRESETS(2).positions = [500,  850, 1200, 1600, 2000, 2350, 2600];

PRESETS(3).name      = 'Aggressive';
PRESETS(3).positions = [600, 1000, 1400, 1800, 2200, 2500, 2700];

%% ============================================================
%%  PHYSICAL PLANT PARAMETERS  (adjust when hardware is available)
%% ============================================================
% Actuator: 12V, 152mm stroke.  Firmware comment says ~12mm/s under load.
ACT_SPEED_MM_PER_S = 12.0;            % [mm/s] under load
MM_PER_COUNT       = 152.0 / 2794;    % 0.0544 mm per ADC count
ACT_SPEED_CPS      = ACT_SPEED_MM_PER_S / MM_PER_COUNT;  % ~220 counts/s

ADC_NOISE_SIGMA    = 5;               % 1-sigma ADC noise [counts]
HALL_JITTER_US     = 50;              % hall pulse timing jitter 1-sigma [us]
ENGINE_TAU_S       = 0.5;             % engine RPM first-order time constant [s]

%% ============================================================
%%  SCENARIO CONFIGURATION  ← change TEST_SCENARIO to switch tests
%% ============================================================
%
%  TEST_SCENARIO values:
%    0 = Standard          RPM ramp + preset switches + RPM spike  (T1-T5, T8)
%    1 = Feedback Fault    Simulates broken ADC wire at t=25s      (T6)
%    2 = Actuator Stall    Simulates mechanical jam at t=20s       (T7)
%    3 = Full Fault Suite  Spike at t=33s then stall at t=55s     (T7+T8)
%
TEST_SCENARIO = 0;

% ---- Base parameters (may be overridden by TEST_SCENARIO below) ----
SIM_DT_MS             = 5;       % timestep [ms] — keep ≤ 10 ms for accuracy
SIM_DURATION_S        = 85;      % total run time [s]
INITIAL_PRESET        = 1;       % 1=Economy, 2=Sport, 3=Aggressive
BUTTON_PRESS_TIMES_S  = [30, 52]; % preset cycle times [s] — [] to disable

% Engine RPM command profile [time_s, rpm] — piecewise linear, interpolated each step
% Profile exercises full extend AND retract paths:
%   t= 0- 2s : idle (allows state machine to stabilize)
%   t= 2-35s : ramp up (RPM crosses 1800 ~t=7s, actuator begins extending)
%   t=35-60s : hold at peak (steady-state tracking test, preset switches at t=30/52)
%   t=60-75s : ramp down to idle (exercises retract path — actuator must follow back)
%   t=75-85s : hold at idle (confirms fail-safe/idle behavior at low RPM)
RPM_PROFILE = [
     0,   800;
     2,   800;
    35,  3900;
    60,  3900;
    75,   800;
    85,   800;
];

% Fault injection defaults (all disabled)
FAULT_FEEDBACK_BREAK_S = Inf;    % broken position wire: ADC → 0  (T6)
FAULT_ACTUATOR_STALL_S = Inf;    % mechanical jam: actuator freezes (T7)
FAULT_RPM_SPIKE_S      = 33.0;   % implausible RPM spike [s]        (T8)
% Spike timing note: must occur near peak RPM (≈3900) so one spike sample
% pushes the 4-sample average above RPM_MAX_VALID=4050.
% t=33s → avg≈4207 RPM → caught.  t=20s → avg≈3273 RPM → silently absorbed.

% ---- Apply scenario overrides ----
switch TEST_SCENARIO
    case 1  % T6 — Feedback sensor wire break → FAIL_SAFE latch
        % ADC wire breaks at t=25s (RPM≈3200, relay actively extending).
        % Firmware detects pos < ACT_FEEDBACK_MIN=10 within one cycle → latches.
        BUTTON_PRESS_TIMES_S  = [];      % isolate fault; no mode changes
        FAULT_FEEDBACK_BREAK_S = 25.0;
        FAULT_ACTUATOR_STALL_S = Inf;
        FAULT_RPM_SPIKE_S      = Inf;

    case 2  % T7 — Actuator mechanical stall → FAIL_SAFE latch
        % Actuator freezes at t=20s (RPM≈2850, relay extending toward target).
        % FAULT_ACT_STALL fires after ACT_STALL_TIMEOUT_MS=5000 ms → t≈25s.
        BUTTON_PRESS_TIMES_S  = [];      % isolate fault; no mode changes
        FAULT_FEEDBACK_BREAK_S = Inf;
        FAULT_ACTUATOR_STALL_S = 20.0;
        FAULT_RPM_SPIKE_S      = Inf;

    case 3  % Full fault suite — non-critical spike (T8) then stall (T7)
        % Spike at t=33s (peak RPM, non-critical — system continues running).
        % Stall at t=55s (sustained max RPM — critical, system latches).
        BUTTON_PRESS_TIMES_S  = [30, 52];
        FAULT_FEEDBACK_BREAK_S = Inf;
        FAULT_ACTUATOR_STALL_S = 55.0;
        FAULT_RPM_SPIKE_S      = 33.0;
end

SCENARIO_NAMES = {'Standard (T1-T5, T8)', 'Feedback Fault (T6)', ...
                  'Actuator Stall (T7)', 'Full Fault Suite (T7+T8)'};
SCENARIO_NAME  = SCENARIO_NAMES{TEST_SCENARIO + 1};

%% ============================================================
%%  PRE-ALLOCATE SIMULATION ARRAYS
%% ============================================================
dt_us = SIM_DT_MS * 1000;
N     = floor(SIM_DURATION_S * 1000 / SIM_DT_MS);

t_ms_arr       = ((0:N-1)' * SIM_DT_MS);
rpm_true_arr   = zeros(N, 1);
rpm_meas_arr   = zeros(N, 1);
act_true_arr   = zeros(N, 1);
act_raw_arr    = zeros(N, 1);
act_filt_arr   = zeros(N, 1);
target_arr     = zeros(N, 1);
rel_fwd_arr    = zeros(N, 1);
rel_rev_arr    = zeros(N, 1);
state_arr      = zeros(N, 1);
fault_arr      = zeros(N, 1);
preset_arr     = ones(N, 1);
torque_arr     = zeros(N, 1);

%% ============================================================
%%  STATE DEFINITIONS  (match firmware enums)
%% ============================================================
ST_IDLE      = 0;
ST_RUNNING   = 1;
ST_FAIL_SAFE = 3;   % 3 chosen to match firmware (no ST_FAULT here; critical → fail-safe)

FAULT_NONE         = 0;
FAULT_ACT_FEEDBACK = 1;   % critical
FAULT_RPM_IMPLAUS  = 3;   % non-critical (matches FAULT_RPM_IMPLAUSIBLE = 3)
FAULT_ACT_STALL    = 4;   % critical
FAULT_ACT_RATE     = 5;   % critical

%% ============================================================
%%  INITIAL STATE
%% ============================================================
% Engine plant
eng_rpm = 800.0;

% Hall / RPM measurement (replicates deltaBuffer[], deltaBufferIdx, deltaBufferCount)
rpm_buf     = zeros(1, RPM_AVG_SAMPLES);
rpm_buf_idx = 0;   % next write index (0-based, incremented mod 4 before write)
rpm_buf_cnt = 0;   % samples filled so far (saturates at RPM_AVG_SAMPLES)
rpm_valid   = false;
rpm_now     = 0.0;
rpm_last_valid = 0.0;
pulse_accum_us      = 0.0;   % fractional pulse accumulator
time_since_pulse_us = RPM_TIMEOUT_US;  % start in timed-out state

% Actuator plant
pos_true  = double(ACT_POS_MIN);  % physical position [counts]
ema_pos   = double(ACT_POS_MIN);  % EMA filter state (pre-loaded at startup cal)

% Relay / direction (replicates lastRelayState, lastDirectionChange)
relay_fwd_on   = false;
relay_rev_on   = false;
dir_state      = 0;          % 0=stopped, 1=fwd, -1=rev (mirrors lastRelayState)
last_dir_chg_ms = -(RELAY_DEADTIME_MS + 1);

% Stall detection (replicates actLastMoveTime, lastActuatorPos, actuatorInDeadband)
stall_last_act_pos = double(ACT_POS_MIN);
stall_last_move_ms = 0;      % initialized to millis() in firmware setup()
in_deadband        = false;

% Rate-of-change fault (replicates prevPosForRate, lastRateCheckTime)
prev_pos_for_rate  = double(ACT_POS_MIN);
last_rate_check_ms = 0;

% State machine
state         = ST_IDLE;
fault         = FAULT_NONE;
fault_latched = false;

% Button / preset cycling
active_preset = INITIAL_PRESET;
btn_fired     = false(1, max(1, length(BUTTON_PRESS_TIMES_S)));
last_btn_ms   = -(BTN_DEBOUNCE_MS + 1);

% One-shot fault injection flags
rpm_spike_done = false;

%% ============================================================
%%  PRINT CONFIGURATION
%% ============================================================
fprintf('Run parameters:\n');
fprintf('  Scenario:     [%d] %s\n', TEST_SCENARIO, SCENARIO_NAME);
fprintf('  Duration:     %.0f s  |  Timestep: %.0f ms  |  Steps: %d\n', ...
    SIM_DURATION_S, SIM_DT_MS, N);
fprintf('  Starting preset:  %s\n', PRESETS(active_preset).name);
fprintf('  Actuator speed:   %.0f counts/s  (%.1f mm/s)\n', ACT_SPEED_CPS, ACT_SPEED_MM_PER_S);
if ~isempty(BUTTON_PRESS_TIMES_S)
    fprintf('  Button presses at t = %s s\n', num2str(BUTTON_PRESS_TIMES_S));
end
if ~isinf(FAULT_FEEDBACK_BREAK_S), fprintf('  [FAULT] Feedback wire break at t=%.1fs\n', FAULT_FEEDBACK_BREAK_S); end
if ~isinf(FAULT_ACTUATOR_STALL_S), fprintf('  [FAULT] Actuator stall at t=%.1fs\n', FAULT_ACTUATOR_STALL_S); end
if ~isinf(FAULT_RPM_SPIKE_S),      fprintf('  [FAULT] RPM spike at t=%.1fs\n', FAULT_RPM_SPIKE_S); end
fprintf('\nRunning...\n\n');

%% ============================================================
%%  MAIN SIMULATION LOOP
%% ============================================================
for k = 1:N
    cur_ms = (k - 1) * SIM_DT_MS;
    cur_s  = cur_ms / 1000.0;

    %% 1. Engine plant — first-order lag response to RPM profile
    rpm_cmd = interp1(RPM_PROFILE(:,1), RPM_PROFILE(:,2), cur_s, ...
                      'linear', RPM_PROFILE(end,2));
    alpha_e = SIM_DT_MS / (ENGINE_TAU_S * 1000 + SIM_DT_MS);
    eng_rpm = eng_rpm + alpha_e * (rpm_cmd - eng_rpm);

    %% 2. Mode button simulation (replicates selectPresetFromButton())
    for bi = 1:length(BUTTON_PRESS_TIMES_S)
        if ~btn_fired(bi) && cur_s >= BUTTON_PRESS_TIMES_S(bi)
            if (cur_ms - last_btn_ms) >= BTN_DEBOUNCE_MS
                btn_fired(bi) = true;
                last_btn_ms   = cur_ms;
                active_preset = mod(active_preset, 3) + 1;
                fprintf('[t=%6.2fs] BUTTON → preset: %s\n', cur_s, PRESETS(active_preset).name);
            end
        end
    end

    %% 3. Hall pulse simulation + RPM measurement (replicates hallISR() + loop steps 1-2)
    if eng_rpm > 50
        pulse_interval_us = 60e6 / (eng_rpm * MAGNETS_PER_REV);
        pulse_accum_us    = pulse_accum_us + dt_us;

        % A pulse fires each time the accumulator crosses the interval threshold.
        % At max RPM (3900) and 5ms step, at most 1 pulse fires per step.
        while pulse_accum_us >= pulse_interval_us
            pulse_accum_us      = pulse_accum_us - pulse_interval_us;
            time_since_pulse_us = 0;

            % Measured delta includes ISR timing jitter (firmware comment: ~0.2us on Cortex-M7)
            jitter        = randn() * HALL_JITTER_US;
            meas_delta_us = max(pulse_interval_us + jitter, 1000);

            % RPM spike injection (one-shot, non-critical fault)
            if ~rpm_spike_done && ~isinf(FAULT_RPM_SPIKE_S) && cur_s >= FAULT_RPM_SPIKE_S
                rpm_spike_done = true;
                % Force an implausibly short delta (equivalent to ~10000 RPM).
                % At true RPM≈3900, this pushes 4-sample avg to ~4474 RPM → exceeds RPM_MAX_VALID.
                meas_delta_us = 60e6 / (10000 * MAGNETS_PER_REV);
                fprintf('[t=%6.2fs] INJECTED: RPM spike (simulated delta → ~10000 RPM)\n', cur_s);
            end

            % Push into circular buffer (replicates deltaBuffer[] / deltaBufferIdx)
            rpm_buf_idx           = mod(rpm_buf_idx, RPM_AVG_SAMPLES) + 1;
            rpm_buf(rpm_buf_idx)  = meas_delta_us;
            rpm_buf_cnt           = min(rpm_buf_cnt + 1, RPM_AVG_SAMPLES);
        end
    end

    % Accumulate time since last pulse (for RPM timeout check)
    time_since_pulse_us = time_since_pulse_us + dt_us;

    % Compute measured RPM once buffer has RPM_AVG_SAMPLES entries (replicates loop step 1)
    if rpm_buf_cnt >= RPM_AVG_SAMPLES && time_since_pulse_us < RPM_TIMEOUT_US
        avg_delta_us = mean(rpm_buf);
        rpm_computed = 60e6 / (avg_delta_us * MAGNETS_PER_REV);

        if rpm_computed > RPM_MAX_VALID
            % Non-critical: reject reading, retain last valid (replicates lastValidRpm)
            fault   = FAULT_RPM_IMPLAUS;
            rpm_now = rpm_last_valid;
        else
            rpm_now       = rpm_computed;
            rpm_last_valid = rpm_computed;
            rpm_valid      = true;
            if fault == FAULT_RPM_IMPLAUS
                fault = FAULT_NONE;  % auto-clear non-critical fault once spike passes
            end
        end
    elseif time_since_pulse_us >= RPM_TIMEOUT_US
        rpm_valid = false;
        rpm_now   = 0.0;
    end

    %% 4. State machine update (replicates loop check of rpmValid + timeout)
    if ~fault_latched
        if rpm_valid && rpm_now > 0
            state = ST_RUNNING;
        elseif time_since_pulse_us >= RPM_TIMEOUT_US
            state = ST_IDLE;
        end
    end

    %% 5. Target position lookup (replicates getActuatorTargetForRpm() + RPM_MIN_CONTROL guard)
    if state == ST_RUNNING
        if rpm_now > 0 && rpm_now < RPM_MIN_CONTROL
            tgt = double(ACT_POS_MIN);
        else
            tgt = fwGetTargetPos(rpm_now, PRESETS(active_preset).positions, ...
                                 RPM_BP, ACT_POS_MIN, ACT_POS_MAX, RPM_MIN_CONTROL);
        end
    else
        tgt = double(ACT_POS_MIN);  % hold retracted during IDLE and FAIL_SAFE
    end

    %% 6. Actuator plant model
    % Physical position updates each step based on relay state.
    % FAULT_ACTUATOR_STALL_S freezes the actuator to test stall detection.
    if isinf(FAULT_ACTUATOR_STALL_S) || cur_s < FAULT_ACTUATOR_STALL_S
        act_delta = ACT_SPEED_CPS * SIM_DT_MS / 1000;  % counts moved this step
        if relay_fwd_on
            pos_true = pos_true + act_delta;
        elseif relay_rev_on
            pos_true = pos_true - act_delta;
        end
        pos_true = max(0, min(4095, pos_true));  % physical endstop
    elseif cur_s >= FAULT_ACTUATOR_STALL_S && ...
           abs(cur_s - FAULT_ACTUATOR_STALL_S) < (SIM_DT_MS/1000 + 1e-6)
        fprintf('[t=%6.2fs] INJECTED: actuator stall (position frozen)\n', cur_s);
    end

    %% 7. Simulated ADC read with noise (replicates analogRead(PIN_ACT_POS) + noise)
    if ~isinf(FAULT_FEEDBACK_BREAK_S) && cur_s >= FAULT_FEEDBACK_BREAK_S
        pos_adc = 0;   % broken wire → reads 0 (below ACT_FEEDBACK_MIN)
        if abs(cur_s - FAULT_FEEDBACK_BREAK_S) < (SIM_DT_MS/1000 + 1e-6)
            fprintf('[t=%6.2fs] INJECTED: position sensor wire break (ADC=0)\n', cur_s);
        end
    else
        pos_adc = round(pos_true + randn() * ADC_NOISE_SIGMA);
        pos_adc = max(0, min(4095, pos_adc));  % 12-bit ADC clamp
    end

    %% 8. EMA filter (replicates emaActuatorPos update + actuatorPos cast)
    ema_pos  = EMA_ALPHA * pos_adc + (1.0 - EMA_ALPHA) * ema_pos;
    pos_filt = round(ema_pos);  % mirrors (int)(emaActuatorPos + 0.5)

    %% 9. Fault detection (replicates checkFaults())
    if ~fault_latched

        % 9a. Feedback out-of-range — critical (wire break or short)
        if pos_adc < ACT_FEEDBACK_MIN || pos_adc > ACT_FEEDBACK_MAX
            fault         = FAULT_ACT_FEEDBACK;
            fault_latched = true;
            state         = ST_FAIL_SAFE;
            fprintf('[t=%6.2fs] CRITICAL FAULT: ACT_FEEDBACK (ADC=%d)\n', cur_s, pos_adc);
        end

        % 9b. Rate-of-change check (critical) — executes every ACT_RATE_CHECK_MS
        if ~fault_latched && (cur_ms - last_rate_check_ms) >= ACT_RATE_CHECK_MS
            pos_delta = abs(pos_filt - prev_pos_for_rate);
            % Only fault if relay is off — normal actuator movement is not a fault
            if pos_delta > ACT_MAX_RATE_PER_CYCLE && ~relay_fwd_on && ~relay_rev_on
                fault         = FAULT_ACT_RATE;
                fault_latched = true;
                state         = ST_FAIL_SAFE;
                fprintf('[t=%6.2fs] CRITICAL FAULT: ACT_RATE (delta=%d counts in 50ms)\n', cur_s, pos_delta);
            end
            prev_pos_for_rate  = pos_filt;
            last_rate_check_ms = cur_ms;
        end

        % 9c. Stall detection (critical) — replicates actLastMoveTime / lastActuatorPos logic
        if ~fault_latched
            relay_active = relay_fwd_on || relay_rev_on;
            if relay_active
                % Check if actuator has moved by more than ACT_DEADBAND/2 = 25 counts
                if abs(pos_filt - stall_last_act_pos) > (ACT_DEADBAND / 2)
                    stall_last_move_ms = cur_ms;   % reset stall timer (movement detected)
                    stall_last_act_pos = pos_filt;
                elseif (cur_ms - stall_last_move_ms) > ACT_STALL_TIMEOUT_MS
                    fault         = FAULT_ACT_STALL;
                    fault_latched = true;
                    state         = ST_FAIL_SAFE;
                    fprintf('[t=%6.2fs] CRITICAL FAULT: ACT_STALL (%.0f ms no movement)\n', ...
                        cur_s, cur_ms - stall_last_move_ms);
                end
            elseif in_deadband
                % Relay stopped AND within deadband → position reached, reset stall timer
                stall_last_move_ms = cur_ms;
                stall_last_act_pos = pos_filt;
            end
        end

    end  % ~fault_latched

    %% 10. Bang-bang actuator control (replicates driveActuator())
    if ~fault_latched && state == ST_RUNNING
        pos_error = tgt - pos_filt;

        if pos_error > ACT_DEADBAND
            new_dir     = 1;    % extend
            in_deadband = false;
        elseif pos_error < -ACT_DEADBAND
            new_dir     = -1;   % retract
            in_deadband = false;
        else
            new_dir     = 0;    % within deadband — stop
            in_deadband = true;
        end

        % Enforce relay deadtime on direction reversals (replicates deadtime guard in driveActuator)
        if new_dir ~= dir_state && new_dir ~= 0
            if (cur_ms - last_dir_chg_ms) < RELAY_DEADTIME_MS
                new_dir = 0;   % coast; not enough time since last direction change
            end
        end

        if new_dir ~= dir_state
            last_dir_chg_ms = cur_ms;
            dir_state       = new_dir;
        end

        relay_fwd_on = (dir_state ==  1);
        relay_rev_on = (dir_state == -1);
    else
        % IDLE or FAIL_SAFE: both relays off (safe state)
        relay_fwd_on = false;
        relay_rev_on = false;
        dir_state    = 0;
        in_deadband  = false;
    end

    %% 11. Torque estimate (replicates calculateTorque())
    if rpm_now > 0
        torque_now = (ENGINE_HP * 5252.0) / rpm_now;
    else
        torque_now = 0.0;
    end

    %% 12. Log step
    t_ms_arr(k)     = cur_ms;
    rpm_true_arr(k) = eng_rpm;
    rpm_meas_arr(k) = rpm_now;
    act_true_arr(k) = pos_true;
    act_raw_arr(k)  = pos_adc;
    act_filt_arr(k) = pos_filt;
    target_arr(k)   = tgt;
    rel_fwd_arr(k)  = relay_fwd_on;
    rel_rev_arr(k)  = relay_rev_on;
    state_arr(k)    = state;
    fault_arr(k)    = fault;
    preset_arr(k)   = active_preset;
    torque_arr(k)   = torque_now;
end

fprintf('Simulation complete.\n\n');

%% ============================================================
%%  SERIAL TELEMETRY OUTPUT  (mirrors firmware CSV format)
%% ============================================================
fprintf('--- Serial Telemetry (firmware format, sampled every %.0fms) ---\n', PRINT_INTERVAL_MS);
fprintf('%-7s  %-8s  %-8s  %-7s  %-7s  %-11s  %s\n', ...
    'Time(s)', 'RPM', 'Torque', 'ActPos', 'Target', 'Preset', 'Status');

step_k = max(1, round(PRINT_INTERVAL_MS / SIM_DT_MS));
for k = 1:step_k:N
    t_s   = t_ms_arr(k) / 1000;
    st    = state_arr(k);
    if st == ST_RUNNING,   s_str = '1 (RUN)';
    elseif st == ST_IDLE,  s_str = '0 (IDLE)';
    else,                  s_str = 'FAIL_SAFE';
    end
    fprintf('%-7.2f  %-8.1f  %-8.2f  %-7.0f  %-7.0f  %-11s  %s\n', ...
        t_s, rpm_meas_arr(k), torque_arr(k), act_filt_arr(k), ...
        target_arr(k), PRESETS(preset_arr(k)).name, s_str);
end

%% ============================================================
%%  AUTOMATED TEST REPORT
%% ============================================================
fprintf('\n=== AUTOMATED TEST REPORT ===\n');

t_s_ax    = t_ms_arr / 1000;
run_mask  = (state_arr == ST_RUNNING);
fs_mask   = (state_arr == ST_FAIL_SAFE);
any_fault = any(fault_arr > 0);

% T1: RPM tracking accuracy vs true engine RPM.
% Exclude a ±2s window around any injected spike — the spike is intentional and
% is tested separately by T8. T1 validates steady-state measurement quality only.
spike_excl_mask = false(N, 1);
if ~isinf(FAULT_RPM_SPIKE_S)
    spike_excl_mask = abs(t_s_ax - FAULT_RPM_SPIKE_S) < 2.0;
end
t1_mask = run_mask & ~spike_excl_mask;
if any(t1_mask)
    rpm_err_arr = abs(rpm_meas_arr(t1_mask) - rpm_true_arr(t1_mask));
    max_rpm_err = max(rpm_err_arr);
else
    max_rpm_err = NaN;
end
pf = fwPass(~isnan(max_rpm_err) && max_rpm_err < 100);
fprintf('[T1] RPM measurement accuracy     max_err = %.1f RPM (spike window excluded)   %s\n', max_rpm_err, pf);

% T2: Position tracking (within 2×deadband of target while RUNNING)
if any(run_mask)
    pos_err_arr   = abs(act_filt_arr(run_mask) - target_arr(run_mask));
    pct_settled   = 100 * mean(pos_err_arr < (2 * ACT_DEADBAND));
else
    pct_settled = 0;
end
pf = fwPass(pct_settled > 65);
fprintf('[T2] Position tracking            %.1f%% of RUNNING time within %d counts   %s\n', ...
    pct_settled, 2*ACT_DEADBAND, pf);

% T3: Position never exceeds software clamps
overtravel = any(act_filt_arr(run_mask | fs_mask) < (ACT_POS_MIN - 20) | ...
                 act_filt_arr(run_mask | fs_mask) > (ACT_POS_MAX + 20));
pf = fwPass(~overtravel);
fprintf('[T3] Actuator software clamps     %s\n', pf);

% T4: Relay deadtime — no reversal gap shorter than RELAY_DEADTIME_MS
relay_dir  = rel_fwd_arr - rel_rev_arr;   % +1=fwd, 0=stop, -1=rev
dir_chg    = find(diff(relay_dir) ~= 0);
dt_ok      = true;
min_gap_ms = Inf;
for ci = 2:length(dir_chg)
    gap_ms = t_ms_arr(dir_chg(ci)) - t_ms_arr(dir_chg(ci-1));
    if gap_ms < min_gap_ms, min_gap_ms = gap_ms; end
    % Allow the stop (0) state in between — only count same-direction back-to-back
    prev_d = relay_dir(dir_chg(ci-1));
    next_d = relay_dir(dir_chg(ci)+1);
    if prev_d ~= 0 && next_d ~= 0 && prev_d ~= next_d
        if gap_ms < RELAY_DEADTIME_MS
            dt_ok = false;
            break;
        end
    end
end
pf = fwPass(dt_ok);
fprintf('[T4] Relay deadtime ≥ %d ms       %s\n', RELAY_DEADTIME_MS, pf);

% T5: State machine entered RUNNING
pf = fwPass(any(run_mask));
fprintf('[T5] State machine → RUNNING      %s\n', pf);

% T6: Feedback fault injection
if isinf(FAULT_FEEDBACK_BREAK_S)
    fprintf('[T6] Feedback fault               SKIPPED (disabled)\n');
else
    triggered  = any(fault_arr == FAULT_ACT_FEEDBACK);
    latched    = any(fs_mask);
    relays_off = ~any(rel_fwd_arr(fs_mask) | rel_rev_arr(fs_mask));
    t6_pass    = triggered && latched && relays_off;
    pf = fwPass(t6_pass);
    if triggered
        t6_trig_s = t_s_ax(find(fault_arr == FAULT_ACT_FEEDBACK, 1));
        fprintf('[T6] Feedback fault: triggered at t=%.2fs, latched=%d, relays_off=%d  %s\n', ...
            t6_trig_s, latched, relays_off, pf);
    else
        fprintf('[T6] Feedback fault: not triggered  %s\n', pf);
    end
end

% T7: Stall fault injection
if isinf(FAULT_ACTUATOR_STALL_S)
    fprintf('[T7] Stall fault                  SKIPPED (disabled)\n');
else
    triggered  = any(fault_arr == FAULT_ACT_STALL);
    latched    = any(fs_mask);
    relays_off = ~any(rel_fwd_arr(fs_mask) | rel_rev_arr(fs_mask));
    t7_pass    = triggered && latched && relays_off;
    pf = fwPass(t7_pass);
    if triggered
        t7_trig_s   = t_s_ax(find(fault_arr == FAULT_ACT_STALL, 1));
        elapsed_s   = t7_trig_s - FAULT_ACTUATOR_STALL_S;
        fprintf('[T7] Stall fault: triggered at t=%.2fs (%.2fs after freeze), latched=%d, relays_off=%d  %s\n', ...
            t7_trig_s, elapsed_s, latched, relays_off, pf);
    else
        fprintf('[T7] Stall fault: not triggered  %s\n', pf);
    end
end

% T8: Implausible RPM spike (non-critical — system continues)
if isinf(FAULT_RPM_SPIKE_S)
    fprintf('[T8] RPM spike fault              SKIPPED (disabled)\n');
else
    spike_caught     = any(fault_arr == FAULT_RPM_IMPLAUS);
    sys_continued    = any(state_arr(t_s_ax > FAULT_RPM_SPIKE_S + 2) == ST_RUNNING);
    pf = fwPass(spike_caught && sys_continued);
    fprintf('[T8] RPM spike caught, system continued  %s\n', pf);
end

fprintf('\n');

%% ============================================================
%%  HELPER: compute fail-safe time regions for shading
%% ============================================================
fs_regions = [];  % Mx2 array of [start_s, end_s]
if any(fs_mask)
    chg      = diff([false; fs_mask; false]);
    fs_starts = t_s_ax(find(chg == 1));
    fs_ends   = t_s_ax(find(chg == -1) - 1);
    if length(fs_starts) == length(fs_ends) + 1
        fs_ends(end+1) = t_s_ax(end);
    end
    if ~isempty(fs_starts)
        fs_regions = [fs_starts(:), fs_ends(:)];
    end
end

%% ============================================================
%%  PLOTS
%% ============================================================
fig = figure('Name', 'eCVT Simulation', 'Position', [30, 30, 1420, 960], ...
             'Color', [0.96 0.96 0.97]);

% ---- 1. Engine RPM ----
ax1 = subplot(4, 2, 1);
shadeRegions(fs_regions, [1 0.75 0.75]);
plot(t_s_ax, rpm_true_arr, 'b-',  'LineWidth', 1.8, 'DisplayName', 'True RPM');
plot(t_s_ax, rpm_meas_arr, 'r--', 'LineWidth', 1.2, 'DisplayName', 'Measured (4-sample avg)');
yline(RPM_MIN_CONTROL, 'g:',  'LineWidth', 1.5, 'DisplayName', sprintf('Control min (%g)', RPM_MIN_CONTROL));
yline(RPM_MAX_VALID,   'm:',  'LineWidth', 1.5, 'DisplayName', sprintf('Valid max (%g)',   RPM_MAX_VALID));
ylabel('RPM'); title('Engine RPM');
legend('Location', 'northwest', 'FontSize', 7); grid on;

% ---- 2. Engine Torque ----
ax2 = subplot(4, 2, 2);
shadeRegions(fs_regions, [1 0.75 0.75]);
plot(t_s_ax, torque_arr, 'm-', 'LineWidth', 1.8);
ylabel('lb-ft'); title(sprintf('Engine Torque  (%.0f HP × 5252 / RPM)', ENGINE_HP)); grid on;

% ---- 3. Actuator Position (main control plot) ----
ax3 = subplot(4, 2, [3 4]);
shadeRegions(fs_regions, [1 0.75 0.75]);
plot(t_s_ax, act_true_arr, 'b-',  'LineWidth', 2.0, 'DisplayName', 'True position');
plot(t_s_ax, act_filt_arr, 'g-',  'LineWidth', 1.5, 'DisplayName', sprintf('EMA filtered (α=%.2f)', EMA_ALPHA));
plot(t_s_ax, target_arr,   'r--', 'LineWidth', 1.8, 'DisplayName', 'Target position');
plot(t_s_ax, act_raw_arr,  'c.',  'MarkerSize', 2,  'DisplayName', 'ADC raw');
yline(ACT_POS_MIN, 'k:', 'LineWidth', 1, 'DisplayName', 'ACT\_POS\_MIN');
yline(ACT_POS_MAX, 'k:', 'LineWidth', 1, 'DisplayName', 'ACT\_POS\_MAX');
% Secondary y-axis label for mm
yl = ylim;
ylabel('ADC counts (0 – 4095)');
title('Actuator Position Control');
% Add physical mm ticks on right side
yyaxis right;
ylabel('Physical position (mm)');
ylim(yl * MM_PER_COUNT);
yyaxis left;
legend('Location', 'northwest', 'FontSize', 7); grid on;

% ---- 4. Relay state ----
ax4 = subplot(4, 2, 5);
shadeRegions(fs_regions, [1 0.75 0.75]);
stairs(t_s_ax,  rel_fwd_arr,  'b-', 'LineWidth', 1.8, 'DisplayName', 'FWD (extend)');
stairs(t_s_ax, -rel_rev_arr,  'r-', 'LineWidth', 1.8, 'DisplayName', 'REV (retract)');
ylim([-1.5, 1.5]); yticks([-1, 0, 1]); yticklabels({'REV', 'OFF', 'FWD'});
title('Relay H-Bridge State'); legend('Location', 'northeast', 'FontSize', 7); grid on;

% ---- 5. State machine ----
ax5 = subplot(4, 2, 6);
shadeRegions(fs_regions, [1 0.75 0.75]);
stairs(t_s_ax, state_arr, 'k-', 'LineWidth', 2);
ylim([-0.5, 3.5]); yticks([0, 1, 3]); yticklabels({'IDLE', 'RUNNING', 'FAIL\_SAFE'});
title('State Machine'); grid on;

% Overlay fault events as vertical markers
fault_times = t_s_ax(diff([0; fault_arr > 0]) == 1);
for ft = fault_times'
    xline(ax5, ft, 'r--', 'LineWidth', 1.5, 'HandleVisibility', 'off');
end

% ---- 6. Position tracking error ----
ax6 = subplot(4, 2, 7);
shadeRegions(fs_regions, [1 0.75 0.75]);
err = target_arr - act_filt_arr;
plot(t_s_ax, err, 'k-', 'LineWidth', 1.2, 'DisplayName', 'Error (target − filtered)');
yline( ACT_DEADBAND, 'g--', 'LineWidth', 1.5, 'DisplayName', sprintf('+%d deadband', ACT_DEADBAND));
yline(-ACT_DEADBAND, 'r--', 'LineWidth', 1.5, 'DisplayName', sprintf('−%d deadband', ACT_DEADBAND));
ylabel('ADC counts'); title('Position Tracking Error');
legend('Location', 'northwest', 'FontSize', 7); grid on;

% ---- 7. CVT operating map ----
ax7 = subplot(4, 2, 8);
rpm_line  = linspace(RPM_BP(1), RPM_BP(end), 300);
clrs      = {'b', 'g', 'r'};
for p = 1:3
    pos_curve = interp1(RPM_BP, PRESETS(p).positions, rpm_line, 'linear');
    plot(rpm_line, pos_curve, [clrs{p} '-'], 'LineWidth', 2, ...
         'DisplayName', PRESETS(p).name);
    hold on;
end
% Overlay actual operating trace, colored by elapsed time
if any(run_mask)
    rr = rpm_meas_arr(run_mask);
    pp = act_filt_arr(run_mask);
    tt = t_s_ax(run_mask);
    scatter(rr, pp, 5, tt, 'filled', 'DisplayName', 'Actual trace (time →)');
    colormap(ax7, 'parula');
    cb = colorbar(ax7);
    cb.Label.String = 'Time (s)';
end
xline(RPM_MIN_CONTROL, 'k:', 'LineWidth', 1.2, 'HandleVisibility', 'off');
xlabel('RPM'); ylabel('Actuator position (counts)');
title('CVT Operating Map — All Presets + Actual Trace');
legend('Location', 'northwest', 'FontSize', 7); grid on;

% Link time axes
xlabel(ax1,'Time (s)'); xlabel(ax2,'Time (s)'); xlabel(ax3,'Time (s)');
xlabel(ax4,'Time (s)'); xlabel(ax5,'Time (s)'); xlabel(ax6,'Time (s)');
linkaxes([ax1, ax2, ax3, ax4, ax5, ax6], 'x');

sgtitle(sprintf('eCVT System MATLAB Simulation  —  Knight Racing Baja SAE  |  Scenario [%d]: %s', ...
    TEST_SCENARIO, SCENARIO_NAME), 'FontSize', 14, 'FontWeight', 'bold');

fprintf('Plots rendered. All time axes are linked — zoom in one to zoom all.\n');
fprintf('Edit the SCENARIO CONFIGURATION section to change test parameters.\n\n');

%% ============================================================
%%  FIGURE 2 — POWER BAND & CVT ANALYSIS
%% ============================================================
% CVT ratio model: linear mapping from actuator position to belt ratio.
% PLACEHOLDER — must be calibrated on the bench dyno with the actual variator.
% At ACT_POS_MIN (fully retracted): high ratio (torque multiplication, low speed).
% At ACT_POS_MAX (fully extended):  low  ratio (speed multiplication, high speed).
CVT_RATIO_HIGH = 3.5;    % ratio at full retraction (low gear) — PLACEHOLDER
CVT_RATIO_LOW  = 0.8;    % ratio at full extension  (high gear) — PLACEHOLDER

% Helper: convert actuator position [counts] to CVT ratio
pos_to_ratio = @(pos) CVT_RATIO_HIGH - ...
    (pos - ACT_POS_MIN) / (ACT_POS_MAX - ACT_POS_MIN) * (CVT_RATIO_HIGH - CVT_RATIO_LOW);

rpm_axis   = linspace(RPM_BP(1), RPM_BP(end), 500);  % 1800–3900 RPM sweep
clrs_p     = [0 0.45 0.74;   % blue  — Economy
              0.47 0.67 0.19; % green — Sport
              0.85 0.33 0.10]; % red  — Aggressive
pnames     = {'Economy', 'Sport', 'Aggressive'};

% Pre-compute curves for all presets across the RPM sweep
pos_curves   = zeros(3, length(rpm_axis));  % actuator position [counts]
mm_curves    = zeros(3, length(rpm_axis));  % actuator extension [mm]
ratio_curves = zeros(3, length(rpm_axis));  % CVT ratio
eng_torque   = (ENGINE_HP * 5252) ./ rpm_axis;  % engine torque [lb-ft]
out_torque   = zeros(3, length(rpm_axis));  % output torque [lb-ft]
out_rpm      = zeros(3, length(rpm_axis));  % output shaft RPM
stroke_pct   = zeros(3, length(rpm_axis));  % actuator stroke used [%]

for p = 1:3
    for ri = 1:length(rpm_axis)
        pos_curves(p,ri) = fwGetTargetPos(rpm_axis(ri), PRESETS(p).positions, ...
            RPM_BP, ACT_POS_MIN, ACT_POS_MAX, RPM_MIN_CONTROL);
    end
    mm_curves(p,:)    = pos_curves(p,:) * MM_PER_COUNT;
    ratio_curves(p,:) = pos_to_ratio(pos_curves(p,:));
    out_torque(p,:)   = eng_torque .* ratio_curves(p,:);
    out_rpm(p,:)      = rpm_axis ./ ratio_curves(p,:);
    stroke_pct(p,:)   = 100 * (pos_curves(p,:) - ACT_POS_MIN) / (ACT_POS_MAX - ACT_POS_MIN);
end

% Relay activity from simulation data
total_steps   = N;
run_steps     = sum(run_mask);
fwd_steps     = sum(rel_fwd_arr & run_mask);
rev_steps     = sum(rel_rev_arr & run_mask);
dead_steps    = sum(~rel_fwd_arr & ~rel_rev_arr & run_mask);

fig2 = figure('Name', 'eCVT Power Band Analysis', ...
    'Position', [80, 80, 1350, 900], 'Color', [0.96 0.96 0.97]);

% ---- P1. Preset control laws (target position vs RPM) ----
axp1 = subplot(3, 2, 1);
for p = 1:3
    plot(rpm_axis, pos_curves(p,:), '-', 'Color', clrs_p(p,:), ...
        'LineWidth', 2.5, 'DisplayName', pnames{p});
    hold on;
end
% Annotate each breakpoint
for p = 1:3
    plot(RPM_BP, PRESETS(p).positions, 'o', 'Color', clrs_p(p,:), ...
        'MarkerSize', 6, 'MarkerFaceColor', clrs_p(p,:), 'HandleVisibility', 'off');
end
xline(RPM_MIN_CONTROL, 'k:', 'LineWidth', 1.5, 'HandleVisibility', 'off');
xlabel('Engine RPM'); ylabel('Actuator position (counts)');
title('Preset Control Laws  (7 breakpoints each)');
legend('Location', 'northwest', 'FontSize', 8); grid on;
% Right-axis in mm
yyaxis right; ylabel('Extension (mm)');
yl = ylim(axp1);
ylim(yl * MM_PER_COUNT); yyaxis left;

% ---- P2. Estimated CVT ratio vs RPM ----
axp2 = subplot(3, 2, 2);
for p = 1:3
    plot(rpm_axis, ratio_curves(p,:), '-', 'Color', clrs_p(p,:), ...
        'LineWidth', 2.5, 'DisplayName', pnames{p});
    hold on;
end
yline(1.0, 'k:', 'LineWidth', 1.5, 'DisplayName', '1:1 ratio');
xlabel('Engine RPM'); ylabel('CVT Ratio (out:in)');
title(sprintf('Estimated CVT Ratio vs RPM\n(PLACEHOLDER: %.1f:1 retracted → %.1f:1 extended — calibrate on bench)', ...
    CVT_RATIO_HIGH, CVT_RATIO_LOW));
legend('Location', 'northeast', 'FontSize', 8); grid on;
% Shade areas: above 1:1 = torque multiplication, below = speed multiplication
ylims2 = ylim;
patch([rpm_axis(1) rpm_axis(end) rpm_axis(end) rpm_axis(1)], ...
    [1.0 1.0 ylims2(2) ylims2(2)], [0.8 0.95 0.8], 'EdgeColor', 'none', ...
    'FaceAlpha', 0.2, 'HandleVisibility', 'off');
patch([rpm_axis(1) rpm_axis(end) rpm_axis(end) rpm_axis(1)], ...
    [ylims2(1) ylims2(1) 1.0 1.0], [0.95 0.8 0.8], 'EdgeColor', 'none', ...
    'FaceAlpha', 0.2, 'HandleVisibility', 'off');
text(rpm_axis(end)-100, 1.05, 'Torque mult.', 'HorizontalAlignment', 'right', ...
    'FontSize', 7, 'Color', [0 0.5 0]);
text(rpm_axis(end)-100, 0.85, 'Speed mult.', 'HorizontalAlignment', 'right', ...
    'FontSize', 7, 'Color', [0.7 0 0]);

% ---- P3. Output shaft torque vs engine RPM (KEY TUNING CHART) ----
axp3 = subplot(3, 2, 3);
for p = 1:3
    plot(rpm_axis, out_torque(p,:), '-', 'Color', clrs_p(p,:), ...
        'LineWidth', 2.5, 'DisplayName', pnames{p});
    hold on;
end
plot(rpm_axis, eng_torque, 'k--', 'LineWidth', 1.5, 'DisplayName', 'Engine torque (no CVT)');
xlabel('Engine RPM'); ylabel('Output torque (lb-ft)');
title('Output Shaft Torque vs Engine RPM  ← KEY TUNING CHART');
legend('Location', 'northeast', 'FontSize', 8); grid on;

% ---- P4. Output shaft RPM vs engine RPM ----
axp4 = subplot(3, 2, 4);
for p = 1:3
    plot(rpm_axis, out_rpm(p,:), '-', 'Color', clrs_p(p,:), ...
        'LineWidth', 2.5, 'DisplayName', pnames{p});
    hold on;
end
plot(rpm_axis, rpm_axis, 'k:', 'LineWidth', 1.2, 'DisplayName', '1:1 (no ratio)');
xlabel('Engine RPM'); ylabel('Output shaft RPM');
title('Output Shaft Speed vs Engine RPM');
legend('Location', 'northwest', 'FontSize', 8); grid on;

% ---- P5. Stroke utilization per preset ----
axp5 = subplot(3, 2, 5);
for p = 1:3
    plot(rpm_axis, stroke_pct(p,:), '-', 'Color', clrs_p(p,:), ...
        'LineWidth', 2.5, 'DisplayName', pnames{p});
    hold on;
end
xlabel('Engine RPM'); ylabel('Stroke used (%)');
title(sprintf('Actuator Stroke Utilization  (0%%=retracted, 100%%=%.0fmm extended)', ...
    ACT_POS_MAX * MM_PER_COUNT));
ylim([0, 105]); legend('Location', 'northwest', 'FontSize', 8); grid on;
% Annotate max stroke per preset at 3900 RPM
for p = 1:3
    pct_max = stroke_pct(p, end);
    text(3900, pct_max + 1.5, sprintf('%.0f%%', pct_max), ...
        'Color', clrs_p(p,:), 'FontSize', 8, 'HorizontalAlignment', 'right');
end

% ---- P6. Relay duty cycle (from simulation run) ----
axp6 = subplot(3, 2, 6);
if run_steps > 0
    labels = {'Extending (FWD)', 'Retracting (REV)', 'In deadband / coasting'};
    sizes  = [fwd_steps, rev_steps, dead_steps];
    clrs_pie = [0.2 0.5 0.9;   % blue — extend
                0.9 0.3 0.2;   % red  — retract
                0.7 0.85 0.7]; % green — deadband
    p_h = pie(axp6, sizes, {'', '', ''});
    for pi_i = 1:3
        p_h(pi_i*2-1).FaceColor = clrs_pie(pi_i,:);
        p_h(pi_i*2-1).EdgeColor = 'w';
    end
    legend(labels, 'Location', 'southoutside', 'FontSize', 8);
    title(sprintf('Relay Activity During RUNNING  (%.0f s of %.0f s total)', ...
        run_steps * SIM_DT_MS / 1000, SIM_DURATION_S));

    % Print percentages as text
    pct_fwd  = 100 * fwd_steps  / run_steps;
    pct_rev  = 100 * rev_steps  / run_steps;
    pct_dead = 100 * dead_steps / run_steps;
    fprintf('Relay duty cycle (RUNNING time):\n');
    fprintf('  Extending:  %.1f%%\n', pct_fwd);
    fprintf('  Retracting: %.1f%%\n', pct_rev);
    fprintf('  In deadband / coasting: %.1f%%\n\n', pct_dead);
else
    text(0.5, 0.5, 'No RUNNING data', 'HorizontalAlignment', 'center', ...
        'Units', 'normalized', 'FontSize', 12);
    title('Relay Activity');
end

sgtitle(sprintf('Power Band & CVT Analysis  —  Baja SAE 10HP  |  CVT ratio model is PLACEHOLDER  |  Scenario [%d]: %s', ...
    TEST_SCENARIO, SCENARIO_NAME), 'FontSize', 13, 'FontWeight', 'bold');

% ---- Separate figure: preset comparison bar chart at key RPMs ----
key_rpms  = [1800, 2150, 2500, 2850, 3200, 3550, 3900];
fig3 = figure('Name', 'eCVT Preset Comparison', ...
    'Position', [120, 120, 1100, 650], 'Color', [0.96 0.96 0.97]);

axb1 = subplot(1, 2, 1);
bar_data_pos = zeros(length(key_rpms), 3);
for p = 1:3
    bar_data_pos(:,p) = PRESETS(p).positions(:);
end
b1 = bar(axb1, key_rpms, bar_data_pos, 'grouped');
for p = 1:3
    b1(p).FaceColor = clrs_p(p,:);
    b1(p).DisplayName = pnames{p};
end
xlabel('Engine RPM'); ylabel('Target actuator position (counts)');
title('Preset Position Targets at Each Breakpoint');
set(axb1, 'XTick', key_rpms);
legend('Location', 'northwest', 'FontSize', 9); grid on;
yyaxis right; ylabel('Extension (mm)');
ylim(ylim(axb1) * MM_PER_COUNT); yyaxis left;

axb2 = subplot(1, 2, 2);
bar_data_ratio = zeros(length(key_rpms), 3);
for p = 1:3
    bar_data_ratio(:,p) = pos_to_ratio(PRESETS(p).positions(:)');
end
b2 = bar(axb2, key_rpms, bar_data_ratio, 'grouped');
for p = 1:3
    b2(p).FaceColor = clrs_p(p,:);
    b2(p).DisplayName = pnames{p};
end
yline(1.0, 'k--', 'LineWidth', 1.5, 'HandleVisibility', 'off');
xlabel('Engine RPM'); ylabel('Estimated CVT Ratio');
title('Estimated CVT Ratio at Each Breakpoint  (PLACEHOLDER)');
set(axb2, 'XTick', key_rpms);
legend('Location', 'northeast', 'FontSize', 9); grid on;

sgtitle(sprintf('Preset Comparison at Breakpoints  —  Knight Racing Baja SAE  |  Scenario [%d]: %s', ...
    TEST_SCENARIO, SCENARIO_NAME), 'FontSize', 13, 'FontWeight', 'bold');

fprintf('Power band figure (Figure 2) and preset comparison (Figure 3) rendered.\n');
fprintf('NOTE: CVT ratio values are PLACEHOLDERS (%.1f:1 → %.1f:1).\n', CVT_RATIO_HIGH, CVT_RATIO_LOW);
fprintf('      Replace CVT_RATIO_HIGH and CVT_RATIO_LOW with measured bench values.\n\n');

%% ============================================================
%%  LOCAL FUNCTIONS
%% ============================================================

function tgt = fwGetTargetPos(rpm_val, positions, rpm_bp, pos_min, pos_max, rpm_min)
    % Replicates getActuatorTargetForRpm() — piecewise linear interpolation.
    % Matches Arduino map() semantics (integer truncation omitted here for fidelity).
    if rpm_val <= 0 || rpm_val < rpm_min
        tgt = double(pos_min);
        return;
    end
    if rpm_val >= rpm_bp(end)
        tgt = double(positions(end));
    else
        tgt = double(positions(1));
        for i = 1 : length(rpm_bp) - 1
            if rpm_val >= rpm_bp(i) && rpm_val < rpm_bp(i+1)
                frac = (rpm_val - rpm_bp(i)) / (rpm_bp(i+1) - rpm_bp(i));
                tgt  = positions(i) + frac * (positions(i+1) - positions(i));
                break;
            end
        end
    end
    tgt = min(max(tgt, pos_min), pos_max);
end

function s = fwPass(cond)
    % Returns coloured PASS/FAIL string for test report.
    if cond, s = 'PASS'; else, s = 'FAIL <<<'; end
end

function shadeRegions(regions, color)
    % Shade time regions (fail-safe periods) in pink behind all plot elements.
    % Call FIRST before plotting data lines so shading stays in the background.
    hold on;
    for i = 1 : size(regions, 1)
        x = [regions(i,1), regions(i,2), regions(i,2), regions(i,1)];
        y = [-1e9, -1e9, 1e9, 1e9];
        patch(x, y, color, 'EdgeColor', 'none', 'FaceAlpha', 0.45, ...
              'HandleVisibility', 'off');
    end
end
