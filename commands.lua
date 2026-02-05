--[[=============================================================================
    HA Light Driver - Proxy Command Handlers (FULL FILE)

    Handles Light V2 proxy commands from C4 Director and translates them to
    Home Assistant service calls via the HA_CALL_SERVICE binding (999).
===============================================================================]]

Helpers = require('helpers')

PROXY_DEVICE_STATE = nil

-- Light capabilities (populated from HA state)
SUPPORTED_ATTRIBUTES = {}
MIN_K_TEMP = 500
MAX_K_TEMP = 20000
HAS_BRIGHTNESS = false
HAS_EFFECTS = false
LAST_EFFECT = "Select Effect"
EFFECTS_LIST = {}

-- Current state tracking
WAS_ON = false
LIGHT_LEVEL = 0  -- Current brightness (Control4 level 0-99)

-- Track last non-zero brightness for "Previous" brightness mode
LAST_LEVEL = 99

-- Daylight Agent preset tracking (used for reporting preset id in CHANGED)
LIGHT_BRIGHTNESS_PRESET_ID = nil
LIGHT_BRIGHTNESS_PRESET_LEVEL = nil

-- Ramp timer state
BRIGHTNESS_RAMP_TIMER = nil
BRIGHTNESS_RAMP_PENDING = false
COLOR_RAMP_TIMER = nil
COLOR_RAMP_PENDING = false
COLOR_RAMP_PENDING_DATA = nil

-- Dim-to-Warm (Color Fade Mode)
COLOR_ON_MODE_FADE_ENABLED = false
COLOR_ON_X = nil
COLOR_ON_Y = nil
COLOR_ON_MODE = nil
COLOR_FADE_X = nil
COLOR_FADE_Y = nil
COLOR_FADE_MODE = nil

-- Defaults
DEFAULT_BRIGHTNESS_RATE = 0  -- ms (from proxy setup)
DEFAULT_COLOR_RATE = 0       -- ms
COLOR_PRESET_ORIGIN = 0      -- 1 = Previous, 2 = Preset
PREVIOUS_ON_COLOR_X = nil
PREVIOUS_ON_COLOR_Y = nil
PREVIOUS_ON_COLOR_MODE = nil

-- Brightness On Mode tracking (from proxy UPDATE_BRIGHTNESS_ON_MODE)
BRIGHTNESS_ON_MODE = "previous"   -- "previous" | "preset"
BRIGHTNESS_PRESET_ID = 0
BRIGHTNESS_PRESET_LEVEL = nil     -- 0-100

-- Button ramp tracking (press/hold approximation)
RAMP_START_TIME_MS = 0
RAMP_DURATION_MS = 0
RAMP_START_LEVEL = 0
RAMP_TARGET_LEVEL = 0

-- Hold detection timer so TOP click doesn't jump to 100%
HOLD_DETECT_TIMER = nil

-- TUNING
HOLD_DETECT_MS = 300               -- delay before starting hold ramp
HOLD_MISFIRE_GRACE_MS = 200        -- if ramp barely started, treat release as click

HOLD_ACTIVE = false
HOLD_PENDING = false
HOLD_PENDING_DIR = nil
HOLD_PENDING_TARGET = nil
HOLD_PRESS_TS = 0
HOLD_RAMP_START_TS = 0

-- FIXED HOLD RATE (5 seconds)
FIXED_HOLD_RATE_MS = 5000

-- Startup / cold boot handling
WAITING_FOR_INITIAL_STATE = true
INITIAL_STATE_TIMEOUT = nil


--[[===========================================================================
    Driver Load Functions
===========================================================================]]

function DRV.OnDriverInit(init)
    -- Immediately present as non-dimmable until HA tells us otherwise
    C4:SendToProxy(5001, 'DYNAMIC_CAPABILITIES_CHANGED', {
        dimmer = false,
        set_level = false,
        supports_target = false,
        supports_color = false,
        supports_color_correlated_temperature = false,
        has_extras = false
    }, "NOTIFY")
end


function DRV.OnDriverLateInit(init)
    local proxyId = C4:GetProxyDevicesById(C4:GetDeviceID())
    local setupResult = C4:SendUIRequest(proxyId, "GET_SETUP", {})
    local setupTable = Helpers.xmlToTable(setupResult)
    setupTable = Helpers.convertTableTypes(setupTable)

    DEFAULT_BRIGHTNESS_RATE = setupTable.light_brightness_rate_default or 0

    if DEBUGPRINT then
        print("[DEBUG OnDriverLateInit] light_brightness_rate_default set: " .. tostring(DEFAULT_BRIGHTNESS_RATE) .. "ms")
    end
	-- Request current HA state on startup
	WAITING_FOR_INITIAL_STATE = true

	-- Ask HA for current state explicitly
	C4:SendToProxy(999, "HA_GET_STATE", {
		ENTITY_ID = EntityID
	})

	-- Safety timeout so driver doesn't hang forever
INITIAL_STATE_TIMEOUT = C4:SetTimer(15000, function()
		INITIAL_STATE_TIMEOUT = nil
		WAITING_FOR_INITIAL_STATE = false
	end)

end

--[[===========================================================================
    Helper Functions
===========================================================================]]

local function GetOnLevel()
    if BRIGHTNESS_ON_MODE == "preset" then
        local lvl = tonumber(BRIGHTNESS_PRESET_LEVEL)
        if lvl and lvl > 0 then return lvl end
        return 99
    end

    local lvl = tonumber(LAST_LEVEL) or tonumber(LIGHT_LEVEL) or 99
    if lvl <= 0 then lvl = 99 end
    return lvl
end

-- CLICK RATE = DEFAULT_BRIGHTNESS_RATE (always)
local function GetClickRateMs(direction)
    return tonumber(DEFAULT_BRIGHTNESS_RATE) or 0
end

-- HOLD RATE = FIXED 5000ms (always)
local function GetHoldRateMs(direction)
    return FIXED_HOLD_RATE_MS
end

function BuildBrightnessChangedParams(level)
    local params = { LIGHT_BRIGHTNESS_CURRENT = level }
    if LIGHT_BRIGHTNESS_PRESET_ID and LIGHT_BRIGHTNESS_PRESET_LEVEL == level then
        params.LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = LIGHT_BRIGHTNESS_PRESET_ID
    end
    return params
end

function SetLightValue(brightnessTarget, rate)
    local tParams = { LIGHT_BRIGHTNESS_TARGET = brightnessTarget }
    if rate ~= nil then tParams.RATE = rate end
    RFP.SET_BRIGHTNESS_TARGET(nil, nil, tParams)
end

--[[===========================================================================
    Proxy Command Handlers (RFP.*)
===========================================================================]]

function RFP.ON(idBinding, strCommand, tParams)
    local lvl = GetOnLevel()
    local rate = tonumber(tParams and tParams.RATE)
    if (rate == nil) or (rate <= 0) then rate = GetClickRateMs("up") end
    SetLightValue(lvl, rate)
end

function RFP.OFF(idBinding, strCommand, tParams)
    local rate = tonumber(tParams and tParams.RATE)
    if (rate == nil) or (rate <= 0) then rate = GetClickRateMs("down") end
    SetLightValue(0, rate)
end

-- Toggle handler (Composer programming -> LIGHT proxy command)
function RFP.TOGGLE(idBinding, strCommand, tParams)
    -- Prefer WAS_ON because HA brightness attribute can remain non-zero even when off
    local isOn = (WAS_ON == true) and (LIGHT_LEVEL > 0)

    if isOn then
        -- Toggle OFF uses down click rate
        SetLightValue(0, GetClickRateMs("down"))
    else
        -- Toggle ON uses your brightness on-mode (previous/preset) + up click rate
        SetLightValue(GetOnLevel(), GetClickRateMs("up"))
    end
end


function RFP.DO_PUSH(idBinding, strCommand, tParams)
    local p = { ACTION = "1", BUTTON_ID = "" }
    if idBinding == 200 then p.BUTTON_ID = "0"
    elseif idBinding == 201 then p.BUTTON_ID = "1"
    elseif idBinding == 202 then p.BUTTON_ID = "2" end
    RFP.BUTTON_ACTION(nil, nil, p)
end

function RFP.DO_RELEASE(idBinding, strCommand, tParams)
    local p = { ACTION = "0", BUTTON_ID = "" }
    if idBinding == 200 then p.BUTTON_ID = "0"
    elseif idBinding == 201 then p.BUTTON_ID = "1"
    elseif idBinding == 202 then p.BUTTON_ID = "2" end
    RFP.BUTTON_ACTION(nil, nil, p)
end

function RFP.DO_CLICK(idBinding, strCommand, tParams)
    local p = { ACTION = "2", BUTTON_ID = "" }
    if idBinding == 200 then p.BUTTON_ID = "0"
    elseif idBinding == 201 then p.BUTTON_ID = "1"
    elseif idBinding == 202 then p.BUTTON_ID = "2" end
    RFP.BUTTON_ACTION(nil, nil, p)
end

function RFP.BUTTON_ACTION(idBinding, strCommand, tParams)

    -- PRESS: delay starting the HOLD ramp so a normal tap doesn't start ramping to 100%
    if tParams.ACTION == "1" then
        if HOLD_DETECT_TIMER then
            HOLD_DETECT_TIMER:Cancel()
            HOLD_DETECT_TIMER = nil
        end

        HOLD_ACTIVE = false
        HOLD_PENDING = true
        HOLD_PRESS_TS = C4:GetTime()
        HOLD_RAMP_START_TS = 0

        local dir = "up"
        if tParams.BUTTON_ID == "1" then dir = "down"
        elseif tParams.BUTTON_ID == "2" and WAS_ON then dir = "down" end
        HOLD_PENDING_DIR = dir

        -- Decide hold ramp target
        if tParams.BUTTON_ID == "0" then
            HOLD_PENDING_TARGET = 100
        elseif tParams.BUTTON_ID == "1" then
            HOLD_PENDING_TARGET = 1
        else
            HOLD_PENDING_TARGET = (WAS_ON and 1) or 100
        end

        HOLD_DETECT_TIMER = C4:SetTimer(HOLD_DETECT_MS, function(timer)
            HOLD_DETECT_TIMER = nil
            if not HOLD_PENDING then return end

            local rate = GetHoldRateMs(HOLD_PENDING_DIR) -- FIXED 5000ms
            RAMP_START_TIME_MS = C4:GetTime()
            RAMP_DURATION_MS = rate
            RAMP_START_LEVEL = LIGHT_LEVEL
            RAMP_TARGET_LEVEL = HOLD_PENDING_TARGET
            HOLD_ACTIVE = true
            HOLD_RAMP_START_TS = RAMP_START_TIME_MS

            SetLightValue(RAMP_TARGET_LEVEL, rate)
        end)

        return
    end

    -- RELEASE: if HOLD never started, treat RELEASE as a CLICK.
    if tParams.ACTION == "0" then
        if HOLD_DETECT_TIMER then
            HOLD_DETECT_TIMER:Cancel()
            HOLD_DETECT_TIMER = nil
        end
        HOLD_PENDING = false

        if not HOLD_ACTIVE then
            if tParams.BUTTON_ID == "0" then
                SetLightValue(GetOnLevel(), GetClickRateMs("up"))
            elseif tParams.BUTTON_ID == "1" then
                SetLightValue(0, GetClickRateMs("down"))
            else
                if WAS_ON then
                    SetLightValue(0, GetClickRateMs("down"))
                else
                    SetLightValue(GetOnLevel(), GetClickRateMs("up"))
                end
            end
            return
        end

        local heldAfterRampMs = 0
        if HOLD_RAMP_START_TS and HOLD_RAMP_START_TS > 0 then
            heldAfterRampMs = C4:GetTime() - HOLD_RAMP_START_TS
        end

        if heldAfterRampMs <= HOLD_MISFIRE_GRACE_MS then
            HOLD_ACTIVE = false
            if tParams.BUTTON_ID == "0" then
                SetLightValue(GetOnLevel(), GetClickRateMs("up"))
            elseif tParams.BUTTON_ID == "1" then
                SetLightValue(0, GetClickRateMs("down"))
            else
                if WAS_ON then
                    SetLightValue(0, GetClickRateMs("down"))
                else
                    SetLightValue(GetOnLevel(), GetClickRateMs("up"))
                end
            end
            return
        end

        HOLD_ACTIVE = false
        SetLightValue(Helpers.lerp(
            RAMP_START_LEVEL,
            RAMP_TARGET_LEVEL,
            C4:GetTime() - RAMP_START_TIME_MS,
            RAMP_DURATION_MS
        ), 0)
        return
    end

    -- CLICK (if proxy sends ACTION=2)
    if tParams.ACTION == "2" then
        if HOLD_DETECT_TIMER then
            HOLD_DETECT_TIMER:Cancel()
            HOLD_DETECT_TIMER = nil
        end
        HOLD_PENDING = false
        HOLD_ACTIVE = false

        if tParams.BUTTON_ID == "0" then
            SetLightValue(GetOnLevel(), GetClickRateMs("up"))
        elseif tParams.BUTTON_ID == "1" then
            SetLightValue(0, GetClickRateMs("down"))
        else
            if WAS_ON then
                SetLightValue(0, GetClickRateMs("down"))
            else
                SetLightValue(GetOnLevel(), GetClickRateMs("up"))
            end
        end
        return
    end
end

function RFP.SYNCHRONIZE(idBinding, strCommand, tParams)
    C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(LIGHT_LEVEL))
end

function RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(idBinding, strCommand, tParams)
    DEFAULT_BRIGHTNESS_RATE = tonumber(tParams.RATE) or 0
    if DEBUGPRINT then
        print("[DEBUG] Default brightness rate set to: " .. tostring(DEFAULT_BRIGHTNESS_RATE) .. "ms")
    end
end

function RFP.UPDATE_COLOR_RATE_DEFAULT(idBinding, strCommand, tParams)
    DEFAULT_COLOR_RATE = tonumber(tParams.RATE) or 0
    if DEBUGPRINT then
        print("[DEBUG] Default color rate set to: " .. tostring(DEFAULT_COLOR_RATE) .. "ms")
    end
end

-- KEEP these handlers (proxy might send them), but they won't change behavior now.
function RFP.SET_CLICK_RATE_UP(idBinding, strCommand, tParams) end
function RFP.SET_CLICK_RATE_DOWN(idBinding, strCommand, tParams) end
function RFP.SET_HOLD_RATE_UP(idBinding, strCommand, tParams) end
function RFP.SET_HOLD_RATE_DOWN(idBinding, strCommand, tParams) end

function RFP.UPDATE_BRIGHTNESS_ON_MODE(idBinding, strCommand, tParams)
    BRIGHTNESS_PRESET_ID = tonumber(tParams.BRIGHTNESS_PRESET_ID) or 0
    BRIGHTNESS_PRESET_LEVEL = tonumber(tParams.BRIGHTNESS_PRESET_LEVEL)

    if BRIGHTNESS_PRESET_ID > 0 and BRIGHTNESS_PRESET_LEVEL ~= nil and BRIGHTNESS_PRESET_LEVEL > 0 then
        BRIGHTNESS_ON_MODE = "preset"
    else
        BRIGHTNESS_ON_MODE = "previous"
    end

    if DEBUGPRINT then
        print("[DEBUG] UPDATE_BRIGHTNESS_ON_MODE: mode=" .. tostring(BRIGHTNESS_ON_MODE) ..
              " preset_id=" .. tostring(BRIGHTNESS_PRESET_ID) ..
              " preset_level=" .. tostring(BRIGHTNESS_PRESET_LEVEL))
    end
end

function RFP.UPDATE_COLOR_PRESET(idBinding, strCommand, tParams)
    if tParams.NAME == "Previous On" then
        PREVIOUS_ON_COLOR_X = tonumber(tParams.COLOR_X)
        PREVIOUS_ON_COLOR_Y = tonumber(tParams.COLOR_Y)
        PREVIOUS_ON_COLOR_MODE = tonumber(tParams.COLOR_MODE)
    end
end

-- === Everything below here stays exactly as your working file ===
-- (ALS handlers, SET_COLOR_TARGET, SET_BRIGHTNESS_TARGET, Parse(), effects, etc.)
-- I did NOT change that logic.


--[[===========================================================================
    Advanced Lighting Scene (ALS) Handlers
===========================================================================]]

function RFP.PUSH_SCENE(idBinding, strCommand, tParams)
    local xml = C4:ParseXml(tParams.ELEMENTS)
    local element = {}

    local nodes = xml.ChildNodes
    if xml.Name == "element" then
        nodes = xml.ChildNodes
    end

    for _, child in ipairs(nodes) do
        local value = child.Value
        if value == "True" or value == "true" then value = true
        elseif value == "False" or value == "false" then value = false
        else value = tonumber(value) or value end
        element[child.Name] = value
    end

    C4:PersistSetValue("ALS:" .. tParams.SCENE_ID, element, false)
end

function RFP.ACTIVATE_SCENE(idBinding, strCommand, tParams)
    local el = C4:PersistGetValue("ALS:" .. tParams.SCENE_ID, false)
    if el == nil then
        print("No scene data for scene " .. tParams.SCENE_ID)
        return
    end

    local levelEnabled = (el.brightnessEnabled == true) or (el.levelEnabled == true)
    local colorEnabled = (el.colorEnabled == true) and el.colorX ~= nil and el.colorY ~= nil

    if (levelEnabled or el.level ~= nil or el.brightness ~= nil) and colorEnabled then
        local target = el.level or el.brightness or 0
        local rate = el.rate or el.brightnessRate or 0
        local colorRate = el.colorRate or 0

        C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGING', {
            LIGHT_BRIGHTNESS_CURRENT = LIGHT_LEVEL,
            LIGHT_BRIGHTNESS_TARGET = target,
            RATE = rate
        })

        C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGING', {
            LIGHT_COLOR_TARGET_X = el.colorX,
            LIGHT_COLOR_TARGET_Y = el.colorY,
            LIGHT_COLOR_TARGET_COLOR_MODE = el.colorMode or 0,
            LIGHT_COLOR_TARGET_COLOR_RATE = colorRate
        })

        if BRIGHTNESS_RAMP_TIMER then BRIGHTNESS_RAMP_TIMER:Cancel(); BRIGHTNESS_RAMP_TIMER = nil end
        if COLOR_RAMP_TIMER then COLOR_RAMP_TIMER:Cancel(); COLOR_RAMP_TIMER = nil end

        local maxRate = math.max(rate, colorRate)
        if maxRate > 0 then
            BRIGHTNESS_RAMP_PENDING = false
            COLOR_RAMP_PENDING = false
            COLOR_RAMP_PENDING_DATA = nil
            BRIGHTNESS_RAMP_TIMER = C4:SetTimer(maxRate, function(timer)
                BRIGHTNESS_RAMP_TIMER = nil
                if BRIGHTNESS_RAMP_PENDING then
                    BRIGHTNESS_RAMP_PENDING = false
                    C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(LIGHT_LEVEL))
                end
                if COLOR_RAMP_PENDING and COLOR_RAMP_PENDING_DATA then
                    COLOR_RAMP_PENDING = false
                    local data = COLOR_RAMP_PENDING_DATA
                    COLOR_RAMP_PENDING_DATA = nil
                    C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGED', {
                        LIGHT_COLOR_CURRENT_X = data.x,
                        LIGHT_COLOR_CURRENT_Y = data.y,
                        LIGHT_COLOR_CURRENT_COLOR_MODE = data.mode
                    })
                end
            end)
        end

        local targetMappedValue = Helpers.C4LevelToHABrightness(target)
        local sceneServiceCall = {
            domain = "light",
            service = "turn_on",
            service_data = { brightness = targetMappedValue },
            target = { entity_id = EntityID }
        }

        sceneServiceCall.service_data.transition = maxRate / 1000

        local lightSupportsCCT = HasValue(SUPPORTED_ATTRIBUTES, "color_temp")
        if lightSupportsCCT and (el.colorMode == 1 or el.colorMode == nil) then
            local kelvin = C4:ColorXYtoCCT(el.colorX, el.colorY)
            sceneServiceCall.service_data.color_temp_kelvin = kelvin
        else
            sceneServiceCall.service_data.xy_color = { el.colorX, el.colorY }
        end

        if target == 0 then
            sceneServiceCall.service_data = { transition = sceneServiceCall.service_data.transition }
            sceneServiceCall.service = "turn_off"
        end

        C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(sceneServiceCall) })
        return
    end

    if levelEnabled or (el.level ~= nil or el.brightness ~= nil) then
        RFP.SET_BRIGHTNESS_TARGET(nil, nil, {
            LIGHT_BRIGHTNESS_TARGET = el.level or el.brightness or 0,
            RATE = el.rate or el.brightnessRate or 0
        })
    end

    if colorEnabled then
        RFP.SET_COLOR_TARGET(nil, nil, {
            LIGHT_COLOR_TARGET_X = el.colorX,
            LIGHT_COLOR_TARGET_Y = el.colorY,
            LIGHT_COLOR_TARGET_MODE = el.colorMode or 0,
            LIGHT_COLOR_TARGET_RATE = el.colorRate or 0
        })
    end
end

function RFP.RAMP_SCENE_UP(idBinding, strCommand, tParams)
    local sceneId = tParams.SCENE_ID
    local rate = tonumber(tParams.RATE)
    if (rate == nil) or (rate <= 0) then
        rate = nil -- will resolve from saved ALS scene or defaults below
    end
    local el = C4:PersistGetValue("ALS:" .. sceneId, false)
    if el == nil then
        print("No scene data for scene " .. tostring(sceneId))
        return
    end
    if rate == nil then
        -- Prefer per-scene ALS rate if present; otherwise fall back to driver default.
        rate = Helpers.NormalizeRate(el and (el.rate or el.brightnessRate), DEFAULT_BRIGHTNESS_RATE)
    end


    local target = el.level or el.brightness or 100
    RAMP_START_TIME_MS = C4:GetTime()
    RAMP_DURATION_MS = rate
    RAMP_START_LEVEL = LIGHT_LEVEL
    RAMP_TARGET_LEVEL = target

    RFP.SET_BRIGHTNESS_TARGET(nil, nil, {
        LIGHT_BRIGHTNESS_TARGET = target,
        RATE = rate
    })
end

function RFP.RAMP_SCENE_DOWN(idBinding, strCommand, tParams)
    local sceneId = tParams.SCENE_ID
    local rate = tonumber(tParams.RATE)
    if (rate == nil) or (rate <= 0) then
        rate = nil -- will resolve from saved ALS scene or defaults below
    end
    local el = C4:PersistGetValue("ALS:" .. sceneId, false)
    if rate == nil then
        -- Prefer per-scene ALS rate if present; otherwise fall back to driver default.
        rate = Helpers.NormalizeRate(el and (el.rate or el.brightnessRate), DEFAULT_BRIGHTNESS_RATE)
    end

    local target = el and (el.level or el.brightness or 100) or 100

    RAMP_START_TIME_MS = C4:GetTime()
    RAMP_DURATION_MS = rate
    RAMP_START_LEVEL = LIGHT_LEVEL
    RAMP_TARGET_LEVEL = 0

    RFP.SET_BRIGHTNESS_TARGET(nil, nil, {
        LIGHT_BRIGHTNESS_TARGET = 0,
        RATE = rate
    })
end

function RFP.STOP_SCENE_RAMP(idBinding, strCommand, tParams)
    local elapsedTimeMs = C4:GetTime() - RAMP_START_TIME_MS

    if BRIGHTNESS_RAMP_TIMER then
        BRIGHTNESS_RAMP_TIMER:Cancel()
        BRIGHTNESS_RAMP_TIMER = nil
    end

    local newTargetLevel = Helpers.lerp(
        RAMP_START_LEVEL,
        RAMP_TARGET_LEVEL,
        elapsedTimeMs,
        RAMP_DURATION_MS
    )

    local stopServiceCall = {
        domain = "light",
        service = "turn_on",
        service_data = {
            brightness = Helpers.C4LevelToHABrightness(newTargetLevel),
            transition = 0
        },
        target = { entity_id = EntityID }
    }

    C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(stopServiceCall) })
end

function RFP.UPDATE_COLOR_ON_MODE(idBinding, strCommand, tParams)
    COLOR_PRESET_ORIGIN = tonumber(tParams.COLOR_PRESET_ORIGIN) or 0

    COLOR_ON_X = tonumber(tParams.COLOR_PRESET_COLOR_X)
    COLOR_ON_Y = tonumber(tParams.COLOR_PRESET_COLOR_Y)
    COLOR_ON_MODE = tonumber(tParams.COLOR_PRESET_COLOR_MODE)

    COLOR_FADE_X = tonumber(tParams.COLOR_FADE_PRESET_COLOR_X)
    COLOR_FADE_Y = tonumber(tParams.COLOR_FADE_PRESET_COLOR_Y)
    COLOR_FADE_MODE = tonumber(tParams.COLOR_FADE_PRESET_COLOR_MODE)

    local fadePresetId = tonumber(tParams.COLOR_FADE_PRESET_ID) or 0
    COLOR_ON_MODE_FADE_ENABLED = (fadePresetId ~= 0) and (COLOR_FADE_X ~= nil) and (COLOR_ON_X ~= nil)
end

function RFP.SET_COLOR_TARGET(idBinding, strCommand, tParams)
    local targetX = tonumber(tParams.LIGHT_COLOR_TARGET_X)
    local targetY = tonumber(tParams.LIGHT_COLOR_TARGET_Y)
    local colorMode = tonumber(tParams.LIGHT_COLOR_TARGET_MODE) or 0
    local rate = tonumber(tParams.LIGHT_COLOR_TARGET_RATE)

    if (rate == nil) or (rate <= 0) then
        rate = DEFAULT_COLOR_RATE
    end


    if COLOR_RAMP_TIMER then
        COLOR_RAMP_TIMER:Cancel()
        COLOR_RAMP_TIMER = nil
    end

    if rate > 0 then
        COLOR_RAMP_PENDING = false
        COLOR_RAMP_PENDING_DATA = nil
        COLOR_RAMP_TIMER = C4:SetTimer(rate, function(timer)
            COLOR_RAMP_TIMER = nil
            if COLOR_RAMP_PENDING and COLOR_RAMP_PENDING_DATA then
                COLOR_RAMP_PENDING = false
                local data = COLOR_RAMP_PENDING_DATA
                COLOR_RAMP_PENDING_DATA = nil
                C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGED', {
                    LIGHT_COLOR_CURRENT_X = data.x,
                    LIGHT_COLOR_CURRENT_Y = data.y,
                    LIGHT_COLOR_CURRENT_COLOR_MODE = data.mode
                })
            end
        end)
    end

    C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGING', {
        LIGHT_COLOR_TARGET_X = targetX,
        LIGHT_COLOR_TARGET_Y = targetY,
        LIGHT_COLOR_TARGET_COLOR_MODE = colorMode,
        LIGHT_COLOR_TARGET_COLOR_RATE = rate
    })

    local colorServiceCall = {
        domain = "light",
        service = "turn_on",
        service_data = {},
        target = { entity_id = EntityID }
    }

    local lightSupportsCCT = HasValue(SUPPORTED_ATTRIBUTES, "color_temp")
    local lightSupportsFullColor = HasValue(SUPPORTED_ATTRIBUTES, "hs") or
        HasValue(SUPPORTED_ATTRIBUTES, "xy") or HasValue(SUPPORTED_ATTRIBUTES, "rgb") or
        HasValue(SUPPORTED_ATTRIBUTES, "rgbw") or HasValue(SUPPORTED_ATTRIBUTES, "rgbww")

    local sendAsCCT = false
    if colorMode == 1 then
        sendAsCCT = lightSupportsCCT
    else
        if lightSupportsFullColor then sendAsCCT = false
        elseif lightSupportsCCT then sendAsCCT = true end
    end

    if sendAsCCT then
        local kelvin = C4:ColorXYtoCCT(targetX, targetY)
        colorServiceCall.service_data.color_temp_kelvin = kelvin
    else
        colorServiceCall.service_data.xy_color = { targetX, targetY }
    end

    if rate > 0 then
        colorServiceCall.service_data.transition = rate / 1000
    end

    C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(colorServiceCall) })
end

function RFP.SET_BRIGHTNESS_TARGET(idBinding, strCommand, tParams)
    if DEBUGPRINT then
        Helpers.dumpTable(tParams, "RFP.SET_BRIGHTNESS_TARGET tParams")
    end

    local target = tonumber(tParams.LIGHT_BRIGHTNESS_TARGET) or 0
    local rate = tonumber(tParams.RATE)
    local presetId = tParams.LIGHT_BRIGHTNESS_TARGET_PRESET_ID

    if (rate == nil) or (rate <= 0) then
        rate = DEFAULT_BRIGHTNESS_RATE
    end

    if presetId ~= nil then
        LIGHT_BRIGHTNESS_PRESET_ID = tonumber(presetId)
        LIGHT_BRIGHTNESS_PRESET_LEVEL = target
    else
        LIGHT_BRIGHTNESS_PRESET_ID = nil
        LIGHT_BRIGHTNESS_PRESET_LEVEL = nil
    end

    if BRIGHTNESS_RAMP_TIMER then
        BRIGHTNESS_RAMP_TIMER:Cancel()
        BRIGHTNESS_RAMP_TIMER = nil
    end

    if rate > 0 then
        BRIGHTNESS_RAMP_PENDING = false
        BRIGHTNESS_RAMP_TIMER = C4:SetTimer(rate, function(timer)
            BRIGHTNESS_RAMP_TIMER = nil
            if BRIGHTNESS_RAMP_PENDING then
                BRIGHTNESS_RAMP_PENDING = false
                C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(LIGHT_LEVEL))
            end
        end)
    end

    C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGING', {
        LIGHT_BRIGHTNESS_CURRENT = LIGHT_LEVEL,
        LIGHT_BRIGHTNESS_TARGET = target,
        RATE = rate
    })

    local targetMappedValue = Helpers.C4LevelToHABrightness(target)
    local brightnessServiceCall = {
        domain = "light",
        service = "turn_on",
        service_data = { brightness = targetMappedValue },
        target = { entity_id = EntityID }
    }

    if HAS_BRIGHTNESS then
        brightnessServiceCall.service_data.transition = rate / 1000
    end

    if target > 0 then
        LAST_LEVEL = target
    end

    local turningOn = (LIGHT_LEVEL == 0 or not WAS_ON) and target > 0
    local colorX, colorY, colorMode = nil, nil, nil

    if target > 0 then
        if COLOR_ON_MODE_FADE_ENABLED and COLOR_ON_X and COLOR_FADE_X then
            colorX = COLOR_FADE_X + (COLOR_ON_X - COLOR_FADE_X) * target * 0.01
            colorY = COLOR_FADE_Y + (COLOR_ON_Y - COLOR_FADE_Y) * target * 0.01
            colorMode = COLOR_ON_MODE
        elseif turningOn then
            if COLOR_PRESET_ORIGIN == 1 and PREVIOUS_ON_COLOR_X then
                colorX = PREVIOUS_ON_COLOR_X
                colorY = PREVIOUS_ON_COLOR_Y
                colorMode = PREVIOUS_ON_COLOR_MODE
            elseif COLOR_PRESET_ORIGIN == 2 and COLOR_ON_X then
                colorX = COLOR_ON_X
                colorY = COLOR_ON_Y
                colorMode = COLOR_ON_MODE
            end
        end

        if colorX and colorY then
            local lightSupportsCCT = HasValue(SUPPORTED_ATTRIBUTES, "color_temp")
            if lightSupportsCCT and (colorMode == 1 or colorMode == nil) then
                local kelvin = C4:ColorXYtoCCT(colorX, colorY)
                brightnessServiceCall.service_data.color_temp_kelvin = kelvin
            else
                brightnessServiceCall.service_data.xy_color = { colorX, colorY }
            end

            C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGING', {
                LIGHT_COLOR_TARGET_X = colorX,
                LIGHT_COLOR_TARGET_Y = colorY,
                LIGHT_COLOR_TARGET_COLOR_MODE = colorMode or 0,
                LIGHT_COLOR_TARGET_COLOR_RATE = DEFAULT_COLOR_RATE
            })
        end
    end

    if not HAS_BRIGHTNESS then
        brightnessServiceCall.service_data = {}
    end

    if target == 0 then
        local transition = brightnessServiceCall.service_data.transition
        brightnessServiceCall.service_data = { transition = transition }
        brightnessServiceCall.service = "turn_off"
    end

    Helpers.dumpTable(brightnessServiceCall, "Brightness Service Call to HA")
    C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(brightnessServiceCall) })
end

function RFP.SET_LEVEL(idBinding, strCommand, tParams)
    tParams["LIGHT_BRIGHTNESS_TARGET"] = tParams.LEVEL
    RFP:SET_BRIGHTNESS_TARGET(strCommand, tParams)
end

function RFP.GROUP_SET_LEVEL(idBinding, strCommand, tParams)
    tParams["LIGHT_BRIGHTNESS_TARGET"] = tParams.LEVEL
    RFP:SET_BRIGHTNESS_TARGET(strCommand, tParams)
end

function RFP.GROUP_RAMP_TO_LEVEL(idBinding, strCommand, tParams)
    tParams["LIGHT_BRIGHTNESS_TARGET"] = tParams.LEVEL
    RFP:SET_BRIGHTNESS_TARGET(strCommand, tParams)
end

function RFP.SELECT_LIGHT_EFFECT(idBinding, strCommand, tParams)
    local brightnessServiceCall = {
        domain = "light",
        service = "turn_on",
        service_data = { effect = tostring(tParams.value) },
        target = { entity_id = EntityID }
    }

    C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(brightnessServiceCall) })
end

--[[===========================================================================
    Home Assistant State Handlers
===========================================================================]]

function RFP.RECEIEVE_STATE(idBinding, strCommand, tParams)
    local jsonData = JSON:decode(tParams.response)
    if jsonData ~= nil then Parse(jsonData) end
end

function RFP.RECEIEVE_EVENT(idBinding, strCommand, tParams)
    local jsonData = JSON:decode(tParams.data)
    if jsonData ~= nil then
        Parse(jsonData["event"]["data"]["new_state"])
    end
end

function Parse(data)
    -- First valid HA state after reboot
	if WAITING_FOR_INITIAL_STATE then
		WAITING_FOR_INITIAL_STATE = false

		if INITIAL_STATE_TIMEOUT then
			INITIAL_STATE_TIMEOUT:Cancel()
			INITIAL_STATE_TIMEOUT = nil
		end
	end

	if data == nil then
        print("NO DATA")
        return
    end

    if data["entity_id"] ~= EntityID then
        return
    end

    if not Connected then
        C4:SendToProxy(5001, 'ONLINE_CHANGED', { STATE = true })
        Connected = true
    end

    local attributes = data["attributes"]
    local state = data["state"]

	if state == "off" then
		WAS_ON = false
		LIGHT_LEVEL = 0
	
		if not WAITING_FOR_INITIAL_STATE then
			C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(0))
		end
	end


    if attributes == nil then
        C4:SendToProxy(5001, 'ONLINE_CHANGED', { STATE = false })
        return
    end

    -- Brightness updates from HA.
    -- IMPORTANT: HA often keeps the last brightness attribute even when the light is OFF.
    -- We use that attribute to keep LAST_LEVEL (for "Previous" Brightness On Mode),
    -- but we only push LIGHT_LEVEL > 0 to the proxy when state is actually "on".
    local selectedAttribute = attributes["brightness"]
    if selectedAttribute ~= nil then
        local mapped = Helpers.HABrightnessToC4Level(tonumber(selectedAttribute)) -- 0-255 -> 0-99

        -- Always keep LAST_LEVEL in sync with HA's last non-zero brightness
        if mapped ~= nil and tonumber(mapped) and tonumber(mapped) > 0 then
            LAST_LEVEL = tonumber(mapped)
        end

        -- Only report non-zero brightness when the light is ON
        if state == "on" then
            LIGHT_LEVEL = tonumber(mapped) or LIGHT_LEVEL

            if BRIGHTNESS_RAMP_TIMER then
                BRIGHTNESS_RAMP_PENDING = true
            else
                C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', BuildBrightnessChangedParams(LIGHT_LEVEL))
            end
        end
    end

    local haColorMode = attributes["color_mode"]

    if haColorMode == "color_temp" then
        local kelvin = attributes["color_temp_kelvin"]
        if kelvin ~= nil then
            local x, y = C4:ColorCCTtoXY(kelvin)
            if COLOR_RAMP_TIMER then
                COLOR_RAMP_PENDING = true
                COLOR_RAMP_PENDING_DATA = { x = x, y = y, mode = 1 }
            else
                C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGED', {
                    LIGHT_COLOR_CURRENT_X = x,
                    LIGHT_COLOR_CURRENT_Y = y,
                    LIGHT_COLOR_CURRENT_COLOR_MODE = 1
                })
            end
        end
    elseif haColorMode ~= nil then
        local xyTable = attributes["xy_color"]
        if xyTable ~= nil then
            if COLOR_RAMP_TIMER then
                COLOR_RAMP_PENDING = true
                COLOR_RAMP_PENDING_DATA = { x = xyTable[1], y = xyTable[2], mode = 0 }
            else
                C4:SendToProxy(5001, 'LIGHT_COLOR_CHANGED', {
                    LIGHT_COLOR_CURRENT_X = xyTable[1],
                    LIGHT_COLOR_CURRENT_Y = xyTable[2],
                    LIGHT_COLOR_CURRENT_COLOR_MODE = 0
                })
            end
        end
    end

    selectedAttribute = attributes["min_color_temp_kelvin"]
    if selectedAttribute ~= nil and MIN_K_TEMP ~= tonumber(selectedAttribute) then
        MIN_K_TEMP = tonumber(selectedAttribute)
    end

    selectedAttribute = attributes["max_color_temp_kelvin"]
    if selectedAttribute ~= nil and MAX_K_TEMP ~= tonumber(selectedAttribute) then
        MAX_K_TEMP = tonumber(selectedAttribute)
    end

    selectedAttribute = attributes["effect"]
    if selectedAttribute ~= nil and LAST_EFFECT ~= selectedAttribute then
        LAST_EFFECT = selectedAttribute
        C4:SendToProxy(5001, 'EXTRAS_STATE_CHANGED', { XML = GetEffectsStateXML() }, 'NOTIFY')
    elseif selectedAttribute == nil then
        LAST_EFFECT = "Select Effect"
        C4:SendToProxy(5001, 'EXTRAS_STATE_CHANGED', { XML = GetEffectsStateXML() }, 'NOTIFY')
    end

    selectedAttribute = attributes["effect_list"]
    if selectedAttribute ~= nil and not TablesMatch(EFFECTS_LIST, selectedAttribute) then
        EFFECTS_LIST = selectedAttribute
        HAS_EFFECTS = true
        C4:SendToProxy(5001, 'EXTRAS_SETUP_CHANGED', { XML = GetEffectsXML() }, 'NOTIFY')
    elseif selectedAttribute == nil then
        EFFECTS_LIST = {}
        HAS_EFFECTS = false
    end

    selectedAttribute = attributes["supported_color_modes"]
    if selectedAttribute ~= nil and not TablesMatch(SUPPORTED_ATTRIBUTES, selectedAttribute) then
        SUPPORTED_ATTRIBUTES = selectedAttribute

        HAS_BRIGHTNESS = true
        local hasColor = false
        local hasCCT = false

        if HasValue(SUPPORTED_ATTRIBUTES, "onoff") then
            HAS_BRIGHTNESS = false
        elseif HasValue(SUPPORTED_ATTRIBUTES, "brightness") then
            HAS_BRIGHTNESS = true
        end

        if GetStatesHasColor() then hasColor = true end
        if GetStatesHasCCT() then hasCCT = true end

        if hasCCT == false then
            MIN_K_TEMP = 0
            MAX_K_TEMP = 0
        end

        local tParams = {
            dimmer = HAS_BRIGHTNESS,
            set_level = HAS_BRIGHTNESS,
            supports_target = HAS_BRIGHTNESS,
            supports_color = hasColor,
            supports_color_correlated_temperature = hasCCT,
            color_correlated_temperature_min = MIN_K_TEMP,
            color_correlated_temperature_max = MAX_K_TEMP,
            has_extras = HAS_EFFECTS
        }

        C4:SendToProxy(5001, 'DYNAMIC_CAPABILITIES_CHANGED', tParams, "NOTIFY")
    end
end

function GetStatesHasColor()
    return HasValue(SUPPORTED_ATTRIBUTES, "hs")
        or HasValue(SUPPORTED_ATTRIBUTES, "xy") or HasValue(SUPPORTED_ATTRIBUTES, "rgb")
        or HasValue(SUPPORTED_ATTRIBUTES, "rgbw") or HasValue(SUPPORTED_ATTRIBUTES, "rgbww")
end

function GetStatesHasCCT()
    return HasValue(SUPPORTED_ATTRIBUTES, "color_temp") or GetStatesHasColor()
end

function GetEffectsStateXML()
    return '<extras_state><extra><object id="effect" value="' .. LAST_EFFECT .. '"/></extra></extras_state>'
end

function GetEffectsXML()
    local items = ""
    for _, effect in pairs(EFFECTS_LIST) do
        items = items .. '<item text="' .. effect .. '" value="' .. effect .. '"/>'
    end
    return '<extras_setup><extra><section label="Effects"><object type="list" id="effect" label="Effect" command="SELECT_LIGHT_EFFECT" value="'
        .. LAST_EFFECT .. '"><list maxselections="1" minselections="1">' .. items .. '</list></object></section></extra></extras_setup>'
end

--[[===========================================================================
    Property Change Handlers (OPC.*)
===========================================================================]]
-- (leave as-is / implement if needed)
