# HA Light Driver v107 - Technical Documentation

## Summary

### New / Improved / Fixed
- **Transition Rate Handling** - Brightness and color ramp times now properly respected in default driver properties page and Advanced Lighting Agent Scene (ALS) definitions.
- **Advanced Lighting Scenes (ALS)** - Full `advanced_scene_support` API implementation
- **Scene Color Tracking** - Scenes now correctly mark as "Active" when color matches within tolerance (see TODO below)

- **Preset ID Support** - Daylight Agent preset tracking for brightness commands
- **Combined Scene Commands** - Brightness and color sent together to prevent visual artifacts
- **Ramp Timer Management** - Deferred state notifications during transitions for accurate scene tracking and UI state tracking

- **Color On Mode Preset**
- **Color On Mode Previous** - Enables the "Previous" color restore option in Composer Pro
- **Color On Mode Fade (Dim-to-Warm)** - Linear color interpolation between dim and bright colors based on brightness level

### TODO

- **Configurable Color Trace Tolerance** - Tried adding an Adjustable Delta E tolerance for scene color matching.  
  Changes to the value are not being respected by the Advanced Lighting scene tracking.  
  The tolerance in CCT space seems to be fixed at around 110 kelvin in the 4000K region.
  I'm sure this works for almost everyone and not many have a need for color tracking for scene activation but it's not working and I believe being ignored by the director.

- **Push and Hold to Ramp** - Applies anything where you push and hold to transition.  This is currently working for brightness via an undesirable workaround. 
  CCT and Color will be difficult or impossible to get working well without a light.stop interface exposed by HomeAssistant to arrest the progress of the ramp.
  Home Assistant's lack of a stop method and minimal state updates during transitions necessitate way more complexity than desirable in this interface.
---

## Technical Details

### 1. Color On Mode Capabilities

Two new capabilities were added to `driver.xml`:

```xml
<capabilities>
    <color_on_mode_previous>True</color_on_mode_previous>
    <color_on_mode_fade>True</color_on_mode_fade>
</capabilities>
```

**`color_on_mode_previous`**: Enables the "Previous" option in Composer Pro's Color On Mode settings. The proxy automatically tracks the last reported color before brightness goes to 0 and restores it on the next turn-on command. No driver-side logic is required beyond declaring the capability.

**`color_on_mode_fade`**: Enables dim-to-warm behavior where the driver calculates an interpolated color based on brightness level.

### 2. Dim-to-Warm Implementation

When the dealer configures "Fade" mode in Composer Pro, the proxy sends `UPDATE_COLOR_ON_MODE` with two color presets:
- **On color** - The target color at 100% brightness
- **Dim color** - The target color at 1% brightness

The driver stores these values:

```lua
COLOR_ON_X, COLOR_ON_Y     -- On color (100%)
COLOR_FADE_X, COLOR_FADE_Y -- Dim color (1%)
COLOR_ON_MODE_FADE_ENABLED -- True when both presets are defined
```

The interpolation formula in `SET_BRIGHTNESS_TARGET`:

```lua
fadeX = COLOR_FADE_X + (COLOR_ON_X - COLOR_FADE_X) * brightness * 0.01
fadeY = COLOR_FADE_Y + (COLOR_ON_Y - COLOR_FADE_Y) * brightness * 0.01
```

The calculated color is sent alongside brightness in a single Home Assistant service call:

```lua
brightnessServiceCall.service_data.color_temp_kelvin = C4:ColorXYtoCCT(fadeX, fadeY)
```

### 3. Suppressing Unwanted Color Commands in Fade Mode

When fade mode is active, the C4 proxy periodically sends `SET_COLOR_TARGET` commands with the preset On or Dim color values. These commands would override the driver's calculated fade color, causing the light to jump to the preset color instead of the interpolated color.

The driver now compares incoming `SET_COLOR_TARGET` coordinates against the stored preset colors and ignores commands that match:

```lua
if COLOR_ON_MODE_FADE_ENABLED then
    -- Check if target matches "On" color
    if COLOR_ON_X and COLOR_ON_Y then
        local dx = math.abs(targetX - COLOR_ON_X)
        local dy = math.abs(targetY - COLOR_ON_Y)
        if dx < 0.005 and dy < 0.005 then
            return  -- Ignore this command
        end
    end

    -- Check if target matches "Dim" color
    if COLOR_FADE_X and COLOR_FADE_Y then
        local dx = math.abs(targetX - COLOR_FADE_X)
        local dy = math.abs(targetY - COLOR_FADE_Y)
        if dx < 0.005 and dy < 0.005 then
            return  -- Ignore this command
        end
    end
end
```

The tolerance of 0.005 in XY space accounts for floating-point rounding. Commands with different colors (e.g., scene activations, manual color changes) pass through normally.

If the Composer UI has other color presets configured that don't match the current On/Dim presets, those sync commands will still reach the driver. 

### 4. Ramp Timer Management

Home Assistant reports the new target state almost immediately when a transition command is sent, rather than waiting for the transition to complete, or sending gradual updates as the luminaire transitions. If the driver forwards this state to C4 when received, C4's user interface elements jump to the fully transitioned state and the ALS scene goes "Active" at the start rather than the end of the transition.

When a brightness or color command includes a rate > 0, the driver:
1. Sets a timer for the duration of the ramp
2. Defers `LIGHT_BRIGHTNESS_CHANGED` and `LIGHT_COLOR_CHANGED` notifications until the timer expires
3. Stores pending state data if HA reports during the ramp

```lua
if rate > 0 then
    BRIGHTNESS_RAMP_PENDING = false
    BRIGHTNESS_RAMP_TIMER = C4:SetTimer(rate, function(timer)
        BRIGHTNESS_RAMP_TIMER = nil
        if BRIGHTNESS_RAMP_PENDING then
            BRIGHTNESS_RAMP_PENDING = false
            C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', ...)
        end
    end)
end
```

In the `Parse()` function that handles HA state updates:

```lua
if BRIGHTNESS_RAMP_TIMER then
    BRIGHTNESS_RAMP_PENDING = true  -- Defer notification
else
    C4:SendToProxy(5001, 'LIGHT_BRIGHTNESS_CHANGED', ...)  -- Immediate
end
```

### 5. Combined Scene Commands

When `ACTIVATE_SCENE` includes both brightness and color, the driver originally executed them as separate HA commands. 
With dim-to-warm enabled, this caused visual flashing and inconsistent state transitions.

When a scene has both brightness and color enabled, send them as a single HA service call:

```lua
if (levelEnabled or el.level ~= nil or el.brightness ~= nil) and colorEnabled then
    local sceneServiceCall = {
        domain = "light",
        service = "turn_on",
        service_data = {
            brightness = targetMappedValue,
            color_temp_kelvin = kelvin,  -- or xy_color
            transition = maxRate / 1000
        },
        target = { entity_id = EntityID }
    }
    C4:SendToProxy(999, "HA_CALL_SERVICE", { JSON = JSON:encode(sceneServiceCall) })
    return  -- Skip individual brightness/color handling
end
```

### 6. C4 Color Conversion Functions

Always use C4's native color conversion functions to stay within C4's color space. C4 uses an implementation for CCT and XY chromaticity that doesn't precisely match well known formulas. 
They also round CCT temps down to the nearest 10k which causes matching issues if you aim for higher precision.  
Just use their color conversion routines whenever possible. 
Be aware also that there is rounding in Home Assistant and this is particularly bad when it's in mired space. Generally we care about CCT's in the 200-400 mired range and rounding down from 199.99 mireds to 199 mireds is a 25k deviation.
Natively, c4 will always manage colors in XY space.

Available functions:
- `C4:ColorCCTtoXY(kelvin)` - Kelvin to CIE 1931 xy
- `C4:ColorXYtoCCT(x, y)` - xy to Kelvin
- `C4:ColorHSVtoXY(h, s, v)` - HSV to xy
- `C4:ColorXYtoHSV(x, y)` - xy to HSV
- `C4:ColorRGBtoXY(r, g, b)` - RGB to xy
- `C4:ColorXYtoRGB(x, y)` - xy to RGB

The round-trip through C4's conversion ensures matching XY coordinates:
1. Receive XY from C4 scene
2. Convert to Kelvin: `C4:ColorXYtoCCT(x, y)`
3. Send to HA as `color_temp_kelvin`
4. Receive `color_temp_kelvin` from HA
5. Convert back: `C4:ColorCCTtoXY(kelvin)`
6. Report to C4 with `LIGHT_COLOR_CHANGED`

### 7. Color Trace Tolerance

Can't get this to work. The `color_trace_tolerance` capability controls scene color matching precision. 

```lua
function OPC.Color_Trace_Tolerance(value)
    COLOR_TRACE_TOLERANCE = tonumber(value) or 1.0
    C4:SendToProxy(5001, 'DYNAMIC_CAPABILITIES_CHANGED', {
        color_trace_tolerance = COLOR_TRACE_TOLERANCE
    }, "NOTIFY")
end
```

Enabling the feature in driver.xml and changing the property at runtime seems to propagate everywhere but I can't tune any more or less color temp tolerance in two ALS scenes that are 'close' but not matching. As mentioned above, around 4000K there is ~110K tolerance to be considered "Active". This works for most applications and addresses the stepping and rounding issues discussed above in almost all cases.

Comparison methods (handled by C4 Director):
- Delta > 0.01: Uses CIE L*a*b* Delta E formula
- Delta <= 0.01: Uses xy chromaticity Euclidean distance


### 8. Preset ID Support

For Daylight Agent integration, the driver tracks preset IDs from `SET_BRIGHTNESS_TARGET`:

```lua
LIGHT_BRIGHTNESS_PRESET_ID = tonumber(tParams.LIGHT_BRIGHTNESS_TARGET_PRESET_ID)
LIGHT_BRIGHTNESS_PRESET_LEVEL = target

function BuildBrightnessChangedParams(level)
    local params = { LIGHT_BRIGHTNESS_CURRENT = level }
    if LIGHT_BRIGHTNESS_PRESET_ID and LIGHT_BRIGHTNESS_PRESET_LEVEL == level then
        params.LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = LIGHT_BRIGHTNESS_PRESET_ID
    end
    return params
end
```

The preset ID is included in `LIGHT_BRIGHTNESS_CHANGED` only when the reported level matches the preset's target level.

### 9. Advanced Lighting Scenes (ALS) Implementation

The driver declares `advanced_scene_support` capability in `driver.xml`:

```xml
<capabilities>
    <advanced_scene_support>True</advanced_scene_support>
</capabilities>
```

This capability requires implementing the following commands:

| Command | Status | Description |
|---------|--------|-------------|
| `PUSH_SCENE` | ✓ Implemented | Stores scene XML data for later activation |
| `ACTIVATE_SCENE` | ✓ Implemented | Executes a stored scene with brightness, color, and rates |
| `RAMP_SCENE_UP` | ✓ Implemented | Ramps to scene's target level (HA lacks continuous ramping) |
| `RAMP_SCENE_DOWN` | ✓ Implemented | Ramps to 0 (HA lacks continuous ramping) |
| `STOP_SCENE_RAMP` | ✓ Implemented | Freezes at current level by sending transition=0 |
| `SYNC_SCENE` | Not needed | Legacy command (pre-3.0.0), handled by PUSH_SCENE |
| `SYNC_ALL_SCENES` | Not needed | Legacy command (pre-3.0.0), handled by PUSH_SCENE |

**PUSH_SCENE**: Parses the scene XML and stores it via `C4:PersistSetValue()`. Scene elements include:
- `level`/`brightness` - Target brightness (0-100)
- `levelEnabled`/`brightnessEnabled` - Whether brightness is part of scene
- `rate`/`brightnessRate` - Transition time in milliseconds
- `colorX`, `colorY` - CIE 1931 xy coordinates
- `colorMode` - 0 (full color) or 1 (CCT)
- `colorEnabled` - Whether color is part of scene
- `colorRate` - Color transition time in milliseconds

**ACTIVATE_SCENE**: Retrieves stored scene data and executes it. When both brightness and color are enabled, they are sent as a single HA command to prevent race conditions with dim-to-warm.

**RAMP_SCENE_UP/DOWN**: Since Home Assistant doesn't support continuous ramping (press-and-hold behavior), we implement these by:
- UP: Ramp to the scene's target brightness level
- DOWN: Ramp to 0

**STOP_SCENE_RAMP**: Sends the current brightness level to HA with `transition=0` to freeze at the current position.

**Note on SYNC_SCENE/SYNC_ALL_SCENES**: Per C4 documentation, these are legacy commands used as workarounds pre-3.0.0. They are not needed if `PUSH_SCENE` is properly handled, which it is.

**Performance requirement**: The driver uses the Brightness Target API (`LIGHT_BRIGHTNESS_CHANGING`/`LIGHT_BRIGHTNESS_CHANGED`) and only sends one level update when the hardware reaches the final scene level. This is achieved through ramp timer management that defers `CHANGED` notifications until the transition completes.

