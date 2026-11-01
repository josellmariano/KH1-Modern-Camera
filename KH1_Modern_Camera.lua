LUAGUI_NAME = "KH1 Modern Camera"
LUAGUI_AUTH = "Mariano"
LUAGUI_DESC = "Modern right-stick camera: analog turning with no inertia, adjustable speed, no automatic vertical recentering."

local MOD_VERSION = "0.4.0"

-- ============================ SETTINGS ============================
-- Players change these in KH1_Modern_Camera_Config.lua in the game folder
-- (next to the game's .exe), not here. The mod creates that file on first
-- launch with every setting below at its default, and updates never touch it.
-- Numbers must be above `min` (or equal to it with `minIncluded`) and at most
-- `max`; each setting becomes a global of the same name.
local SETTINGS = {
    { name = "CameraSpeed", default = 1.4, min = 0, max = 10,
      help = "Top turn speed, as a multiple of vanilla (above 0, up to 10).\n"
          .. "1.0 = 150 degrees per second at full tilt, 1.4 = 210." },
    { name = "PitchSpeed", default = 0.85, min = 0, max = 3,
      help = "Vertical turn speed relative to horizontal (above 0, up to 3)." },
    { name = "DirectStick", default = true,
      help = "true = the camera turns straight from the stick: analog, no inertia.\n"
          .. "false = the game's own handling, at CameraSpeed." },
    { name = "ResponseCurve", default = 1.5, min = 0, max = 5,
      help = "DirectStick: 1 = linear; higher = finer control on small tilts\n"
          .. "(above 0, up to 5)." },
    { name = "Deadzone", default = 0.2, min = 0, minIncluded = true, max = 0.9,
      help = "DirectStick: share of stick travel ignored (0 to 0.9). Raise it if the\n"
          .. "camera drifts. The game already ignores the first ~20%, so lower does nothing." },
    { name = "InvertX", default = false,
      help = "DirectStick: flip left/right turning. (The in-game camera invert\n"
          .. "options don't apply with DirectStick.)" },
    { name = "InvertY", default = false,
      help = "DirectStick: flip up/down turning." },
    { name = "HoldPitch", default = true,
      help = "Stop the game from recentering the camera's vertical angle." },
    { name = "PitchJumpThreshold", default = 0.1, min = 0, max = 3.2,
      help = "HoldPitch: one-frame vertical jumps bigger than this, in radians (room\n"
          .. "loads, cutscenes), are kept instead of undone (above 0, up to 3.2)." },
    { name = "DebugPitch", default = false,
      help = "Print each undone recentering step to the LuaBackend console." },
}
local CONFIG_FILE = "KH1_Modern_Camera_Config.lua"   -- relative to the game folder
-- ==================================================================

-- Steam Global only: every address below was found or verified on it.
local FINGERPRINT_ADDR = 0x3B2271
local FINGERPRINT      = 0x7265737563697065

-- Right-stick turn constants (rad/frame). While the stick is held the turn
-- velocity grows by ACCEL per frame up to MAX; after release it shrinks by
-- FRICTION per frame. Stick tilt only scales the growth, so any tilt ends up
-- at full speed - that and the ramp are what DirectStick replaces.
local CAM_ACCEL        = 0x3EA3B8
local CAM_FRICTION     = 0x3EA3BC
local CAM_MAX          = 0x3EA3CC
local VANILLA_ACCEL    = 0.002617994091
local VANILLA_FRICTION = 0.004188790452
local VANILLA_MAX      = 0.04363323376   -- 2.5 degrees per frame

-- Camera block. The game adds YAW_VEL / PITCH_VEL to the angles every frame
-- and applies the pitch limits itself.
local CAM_PITCH   = 0x2537E80
local CAM_YAW     = 0x2537E84
local PITCH_VEL   = CAM_PITCH + 0x26C
local YAW_VEL     = CAM_PITCH + 0x270
local LOCK_TARGET = 0x2537F00

-- Controller state (pointer from CameraSpeedSlider). Right stick is one byte
-- per axis, 0..255 with 128 at rest; right/down are high. The game's input
-- layer already holds it at 128 until the stick is ~20% out.
local PAD_DEVICE    = 0x21AAF18
local PAD_CONNECTED = 0x37
local PAD_RX        = 0x1A
local PAD_RY        = 0x1B
local PAD_DEADZONE  = 26

-- Velocity sign per stick direction for a non-inverted camera: stick right
-- turns yaw positive; stick up (low byte) needs a positive pitch velocity.
local YAW_DIR   = 1
local PITCH_DIR = -1

local active
local wantMax, deadzoneBytes
local lastWritten, foreignWrites
local heldPitch, prevPitch, stuckFrames
local yawSign, pitchSign
local wasDirect

local function say(msg)
    ConsolePrint("KH1 Modern Camera - " .. msg)
end

-- A setting's value as it is written in the config file.
local function luaValue(v)
    if math.type(v) == "float" and v == math.floor(v) then
        return string.format("%.1f", v)
    end
    return tostring(v)
end

local function writeDefaultConfig()
    local lines = {
        "-- KH1 Modern Camera settings",
        "-- Change a value, save, then restart the game. Delete a line to use its",
        "-- default, or delete this file to have the mod recreate it.",
        "",
    }
    for _, s in ipairs(SETTINGS) do
        for line in s.help:gmatch("[^\n]+") do lines[#lines + 1] = "-- " .. line end
        lines[#lines + 1] = s.name .. " = " .. luaValue(s.default)
        lines[#lines + 1] = ""
    end
    local f = io.open(CONFIG_FILE, "w")
    if not f then
        say("could not create " .. CONFIG_FILE .. " in the game folder. Using the defaults.")
        return
    end
    f:write(table.concat(lines, "\n"))
    f:close()
    say("created " .. CONFIG_FILE .. " in the game folder with the default settings")
end

-- The config file's assignments as a table, e.g. { CameraSpeed = 1.2 }. A
-- missing file is created with the defaults; a broken one is reported.
local function readConfig()
    local f = io.open(CONFIG_FILE, "r")
    if not f then
        writeDefaultConfig()
        return {}
    end
    local text = f:read("a"):gsub("^\239\187\191", "")   -- tolerate a UTF-8 BOM
    f:close()
    local cfg = {}
    local chunk, err = load(text, "=" .. CONFIG_FILE, "t", cfg)
    local ok = chunk ~= nil
    if ok then ok, err = pcall(chunk) end
    if not ok then
        say("error in " .. CONFIG_FILE .. ", using the defaults: " .. tostring(err))
        return {}
    end
    return cfg
end

-- Set every setting from the config file, or its default when the file
-- leaves it out or the value is invalid (reported). Unknown names are
-- reported too, since they are usually typos.
local function loadSettings()
    local cfg = readConfig()
    local known, changed = {}, 0
    for _, s in ipairs(SETTINGS) do
        known[s.name] = true
        local v = cfg[s.name]
        if v == nil then v = s.default end
        local ok = type(v) == type(s.default)
        if ok and s.max then
            ok = v <= s.max and (v > s.min or s.minIncluded and v == s.min)
        end
        if not ok then
            say(string.format("%s = %s is not valid (%s). Using %s.", s.name, tostring(v),
                s.max and string.format("a number %s %g, up to %g",
                    s.minIncluded and "from" or "above", s.min, s.max) or "true or false",
                luaValue(s.default)))
            v = s.default
        end
        if v ~= s.default then changed = changed + 1 end
        _ENV[s.name] = v
    end
    for name in pairs(cfg) do
        if not known[name] then
            say("unknown setting " .. tostring(name) .. " in " .. CONFIG_FILE .. " (typo?)")
        end
    end
    if changed > 0 then
        say(string.format("%d setting(s) changed from the defaults", changed))
    end
end

-- Values the frame code needs, derived from the settings.
local function applySettings()
    deadzoneBytes = math.max(PAD_DEADZONE, Deadzone * 127)
    wantMax   = VANILLA_MAX * CameraSpeed
    yawSign   = InvertX and -YAW_DIR or YAW_DIR
    pitchSign = InvertY and -PITCH_DIR or PITCH_DIR
end

-- Byte axis to -1..1: 0 inside the deadzone, then rising smoothly from just
-- outside it to full tilt, shaped by ResponseCurve.
local function stickAxis(b)
    local d = b - 128
    local mag = math.abs(d)
    if mag <= deadzoneBytes then return 0 end
    local t = math.min(1, (mag - deadzoneBytes) / (127 - deadzoneBytes)) ^ ResponseCurve
    return d > 0 and t or -t
end

-- Right stick as two -1..1 axes, or nil when no controller is connected.
local function readRightStick()
    local ok, dev = pcall(ReadLong, PAD_DEVICE)
    if not ok or not dev or dev == 0 then return nil end
    local ok2, connected = pcall(ReadByte, dev + PAD_CONNECTED, true)
    if not ok2 or connected ~= 1 then return nil end
    local ok3, rx = pcall(ReadByte, dev + PAD_RX, true)
    local ok4, ry = pcall(ReadByte, dev + PAD_RY, true)
    if not (ok3 and ok4) then return nil end
    return stickAxis(rx), stickAxis(ry)
end

-- Keep the turn constants at what this mode needs. Direct mode zeroes
-- acceleration and friction so the game leaves the velocities we write alone.
-- If they keep changing after we wrote them, another mod (CameraSpeedSlider)
-- is fighting us; say so once.
local function syncTurnConstants(direct)
    local want = {
        direct and 0 or VANILLA_ACCEL * CameraSpeed,
        direct and 0 or VANILLA_FRICTION * CameraSpeed,
        wantMax,
    }
    local addrs = { CAM_ACCEL, CAM_FRICTION, CAM_MAX }
    for i, addr in ipairs(addrs) do
        local cur = ReadFloat(addr)
        if lastWritten[i] and math.abs(cur - lastWritten[i]) > 1e-6 then
            foreignWrites = foreignWrites + 1
            if foreignWrites == 120 then
                ConsolePrint("KH1 Modern Camera - another mod keeps changing the camera "
                    .. "speed. Disable CameraSpeedSlider (or similar) in Mods Manager.")
            end
        end
        if math.abs(cur - want[i]) > 1e-6 then
            WriteFloat(addr, want[i])
        end
        lastWritten[i] = want[i]
    end
end

-- Undo the game's vertical recentering. The game eases pitch toward 0
-- (~3% per frame) on stick release or when Sora moves. Each frame the pitch
-- should have moved by exactly the pitch velocity the game applied (it
-- subtracts it), so anything else is recentering and gets reverted - also
-- mid-turn, e.g. a diagonal stick move while Sora runs. Kept as-is: big
-- one-frame jumps (room loads), and the game's pitch limits, recognised by
-- the pitch not moving while the stick pushes. Lock-on is left alone so
-- lock-on camera mods can steer the pitch.
--
-- `vel` is the pitch velocity read before this frame's write, i.e. the one
-- the game just applied. Only direct mode knows it exactly; with the game's
-- own stick handling, pitch changes while turning are accepted as before.
local function holdPitch(vel, direct)
    local yaw = ReadFloat(CAM_YAW)
    if ReadLong(LOCK_TARGET) ~= 0 or not (math.abs(yaw) <= 3.5) then
        heldPitch = nil   -- locked on, or camera not loaded (title, loading)
        return
    end

    local pitch = ReadFloat(CAM_PITCH)
    if pitch ~= pitch or vel ~= vel then heldPitch = nil return end
    if heldPitch == nil then
        heldPitch, prevPitch, stuckFrames = pitch, pitch, 0
        return
    end

    local moving = math.abs(vel) >= 0.00001
    if moving and not direct then
        heldPitch, prevPitch, stuckFrames = pitch, pitch, 0
        return
    end

    local expected = heldPitch - (moving and vel or 0)
    if moving and math.abs(pitch - prevPitch) < 0.00001 then
        stuckFrames = stuckFrames + 1
    else
        stuckFrames = 0
    end
    prevPitch = pitch

    local delta = pitch - expected
    if math.abs(delta) < 0.00001 then
        heldPitch = pitch
    elseif math.abs(delta) > PitchJumpThreshold then
        heldPitch = pitch          -- room load or cutscene
    elseif stuckFrames >= 2 then
        heldPitch = pitch          -- stick pushing into the game's pitch limit
    else
        if DebugPitch then
            ConsolePrint(string.format("pitch hold: undid %.4f", delta))
        end
        WriteFloat(CAM_PITCH, expected)
        heldPitch = expected
    end
end

function _OnInit()
    active        = ReadLong(FINGERPRINT_ADDR) == FINGERPRINT
    lastWritten   = {}
    foreignWrites = 0
    heldPitch     = nil
    wasDirect     = false

    if not active then
        ConsolePrint(string.format("KH1 Modern Camera v%s - NOT running: only the "
            .. "Steam Global version is supported. Nothing will be written.", MOD_VERSION))
        return
    end
    loadSettings()
    applySettings()
    ConsolePrint(string.format("KH1 Modern Camera v%s - installed (Steam GL, "
        .. "speed %.1fx)", MOD_VERSION, CameraSpeed))
end

function _OnFrame()
    if not active then return end
    local appliedPitchVel = ReadFloat(PITCH_VEL)

    local sx, sy
    if DirectStick then sx, sy = readRightStick() end
    local direct = sx ~= nil

    syncTurnConstants(direct)
    if direct then
        WriteFloat(YAW_VEL, sx * yawSign * wantMax)
        WriteFloat(PITCH_VEL, sy * pitchSign * wantMax * PitchSpeed)
    end
    -- The velocity just applied came from last frame's mode.
    if HoldPitch then holdPitch(appliedPitchVel, direct and wasDirect) end
    wasDirect = direct
end
