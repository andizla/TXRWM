-- TXR Weather Mod v3.0
-- systems/shadows.lua
-- Dynamic shadow distance scaling based on FOV

local Shadows = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")

-- Lazy-load Actors to avoid circular dependencies
local Actors = nil

local MODULE = "Shadows"

-- ============== STATE ==============
local isInitialized = false
local currentDistance = 55000
local currentFOV = 90

-- ============== CONFIGURATION ==============
-- Lookup table: FOV -> minimum shadow distance (with ~5000 headroom)
-- Based on testing data
local FOV_DISTANCE_TABLE = {
    [10] = 152000, [11] = 152000, [12] = 152000, [13] = 151000, [14] = 151000,
    [15] = 151000, [16] = 150000, [17] = 150000, [18] = 149000, [19] = 149000,
    [20] = 149000, [21] = 148000, [22] = 148000, [23] = 147000, [24] = 147000,
    [25] = 146000, [26] = 145000, [27] = 145000, [28] = 144000, [29] = 144000,
    [30] = 143000, [31] = 142000, [32] = 142000, [33] = 141000, [34] = 140000,
    [35] = 139000, [36] = 139000, [37] = 138000, [38] = 137000, [39] = 136000,
    [40] = 135000, [41] = 134000, [42] = 133000, [43] = 133000, [44] = 132000,
    [45] = 131000, [46] = 130000, [47] = 129000, [48] = 128000, [49] = 127000,
    [50] = 126000, [51] = 125000, [52] = 124000, [53] = 123000, [54] = 122000,
    [55] = 121000, [56] = 120000, [57] = 119000, [58] = 118000, [59] = 117000,
    [60] = 116000, [61] = 115000, [62] = 114000, [63] = 113000, [64] = 111000,
    [65] = 110000, [66] = 109000, [67] = 108000, [68] = 107000, [69] = 106000,
    [70] = 104000, [71] = 103000, [72] = 102000, [73] = 101000, [74] = 100000,
    [75] = 99000,  [76] = 97000,  [77] = 96000,  [78] = 95000,  [79] = 94000,
    [80] = 93000,  [81] = 91000,  [82] = 90000,  [83] = 88000,  [84] = 87000,
    [85] = 86000,  [86] = 85000,  [87] = 84000,  [88] = 83000,  [89] = 82000,
    [90] = 81000,  [91] = 79000,  [92] = 78000,  [93] = 77000,  [94] = 75000,
    [95] = 74000,  [96] = 73000,  [97] = 72000,  [98] = 71000,  [99] = 70000,
    [100] = 69000, [101] = 67000, [102] = 66000, [103] = 65000, [104] = 64000,
    [105] = 63000, [106] = 62000, [107] = 61000, [108] = 60000, [109] = 59000,
    [110] = 58000, [111] = 57000, [112] = 56000, [113] = 55000, [114] = 54000,
    [115] = 53000, [116] = 52000, [117] = 51000, [118] = 51000, [119] = 48000,
    [120] = 45000,
}

-- Fallback for FOV outside table range
local SHADOW_MIN = 45000   -- Floor for FOV > 120
local SHADOW_MAX = 155000  -- Cap for FOV < 10

-- ============== INTERNAL FUNCTIONS ==============

local function getActors()
    if not Actors then
        local success, mod = pcall(require, "systems.actors")
        if success then Actors = mod end
    end
    return Actors
end

--- Calculate shadow distance based on FOV
--- @param fov number Current field of view
--- @return number Shadow distance
local function calculateDistance(fov)
    -- Round FOV to nearest integer for table lookup
    local fovInt = math.floor(fov + 0.5)
    
    -- Clamp to table range
    if fovInt < 10 then
        return SHADOW_MAX
    elseif fovInt > 120 then
        return SHADOW_MIN
    end
    
    -- Lookup from table
    local distance = FOV_DISTANCE_TABLE[fovInt]
    if distance then
        return distance
    end
    
    -- Fallback interpolation if somehow missing
    return SHADOW_MAX - (fovInt - 10) * 1000
end

--- Get current FOV from PlayerCameraManager
--- @return number FOV angle
local function getCurrentFOV()
    local fov = 90  -- Default fallback
    pcall(function()
        local pcm = FindFirstOf("PlayerCameraManager")
        if pcm then
            local getFOV = pcm["GetFOVAngle"]
            if getFOV then
                fov = getFOV(pcm)
            end
        end
    end)
    return fov
end

--- Apply shadow distance to sun light component
--- @param distance number Shadow distance to apply
--- @return boolean success
local function applyDistance(distance)
    local actors = getActors()
    if not actors then return false end
    
    local uds = actors.GetUDS()
    if not uds then return false end
    
    local sunLight = nil
    pcall(function()
        sunLight = uds["Sun_LightComponent"]
    end)
    
    if not sunLight then return false end
    
    local ok = pcall(function()
        local setMovable = sunLight["SetDynamicShadowDistanceMovableLight"]
        if setMovable then
            setMovable(sunLight, distance)
        end
        
        local setStationary = sunLight["SetDynamicShadowDistanceStationaryLight"]
        if setStationary then
            setStationary(sunLight, distance)
        end
        
        -- Higher exponent = more shadow resolution near camera
        local setCascadeExp = sunLight["SetCascadeDistributionExponent"]
        if setCascadeExp then
            setCascadeExp(sunLight, 3.0)
        end
    end)
    
    return ok
end

-- ============== PUBLIC API ==============

--- Initialize shadows module
--- @return boolean success
function Shadows.Init()
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end
    
    Log.Info(MODULE, "Initializing shadows module")
    isInitialized = true
    State.SetModuleStatus("shadows", true)
    
    return true
end

--- Update shadow distance based on current FOV
--- Call this periodically or on FOV change
--- @return boolean success
function Shadows.Update()
    local fov = getCurrentFOV()
    local distance = calculateDistance(fov)
    
    -- Only apply if changed significantly
    if math.abs(distance - currentDistance) >= 1000 or math.abs(fov - currentFOV) >= 1 then
        local ok = applyDistance(distance)
        if ok then
            currentDistance = distance
            currentFOV = fov
            Log.Debug(MODULE, "Shadow distance updated", {distance = distance, fov = string.format("%.1f", fov)})
        end
        return ok
    end
    
    return true
end

--- Force apply shadow distance (ignores change threshold)
--- @return boolean success
function Shadows.Apply()
    local fov = getCurrentFOV()
    local distance = calculateDistance(fov)
    
    local ok = applyDistance(distance)
    if ok then
        currentDistance = distance
        currentFOV = fov
        Log.Info(MODULE, "Shadow distance applied", {distance = distance, fov = string.format("%.1f", fov)})
    else
        Log.Warn(MODULE, "Failed to apply shadow distance")
    end
    
    return ok
end

--- Get current shadow state
--- @return table {distance, fov, initialized}
function Shadows.GetStatus()
    return {
        distance = currentDistance,
        fov = currentFOV,
        initialized = isInitialized
    }
end

--- Get current shadow distance
--- @return number
function Shadows.GetDistance()
    return currentDistance
end

--- Get current FOV
--- @return number
function Shadows.GetFOV()
    return currentFOV
end

--- Check if initialized
--- @return boolean
function Shadows.IsInitialized()
    return isInitialized
end

return Shadows
