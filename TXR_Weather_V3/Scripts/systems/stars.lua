-- TXR Weather Mod v3.0
-- systems/stars.lua
-- Phase 12: High-resolution (HD) real-stars night sky
-- Reference: V1.34 uds_stars.lua (technique only; wiring follows V3 architecture)

local Stars = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-load to avoid circular dependencies
local Actors = nil

local MODULE = "Stars"

-- ============== CONFIGURATION (filled in Init, with safe fallbacks) ==============
local enabled = true
local hdStars = true
local texturePath = "/Game/UltraDynamicSky/Textures/Sky/Real_Stars.Real_Stars"
local tiling = 1.0
local intensity = nil  -- nil = keep project/UDS default

-- ============== UDS PROPERTY NAMES ==============
local PROP_SIMULATE_REAL_STARS = "Simulate Real Stars"
local PROP_REAL_STARS_TEXTURE  = "Real Stars Texture"
local PROP_STARS_TILING        = "Stars Tiling"
local PROP_STARS_INTENSITY     = "Stars Intensity"
local PROP_REFRESH             = "Refresh Settings"

-- ============== STATE ==============
local isInitialized = false
local applied = false
local originalTexture = nil  -- captured before swap so we can restore the stock texture

-- ============== INTERNAL FUNCTIONS ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getUDS()
    local actors = getActors()
    if not actors then return nil end
    return actors.GetUDS()
end

local function isValidObj(o)
    if not o then return false end
    local ok, valid = pcall(function() return o.IsValid and o:IsValid() end)
    return ok and valid or false
end

local function writeUDS(prop, value)
    local uds = getUDS()
    if not uds then return false end
    local ok = pcall(function() uds[prop] = value end)
    return ok
end

local function readUDS(prop)
    local uds = getUDS()
    if not uds then return nil end
    local v = nil
    pcall(function() v = uds[prop] end)
    return v
end

--- Resolve a texture asset: prefer already-loaded, fall back to loading from disk.
--- @param path string Asset path
--- @return userdata|nil
local function loadAsset(path)
    if not path or path == "" then return nil end
    local obj = nil
    if StaticFindObject then
        pcall(function() obj = StaticFindObject(path) end)
    end
    if not isValidObj(obj) and StaticLoadObject then
        pcall(function() obj = StaticLoadObject(nil, nil, path) end)
    end
    return isValidObj(obj) and obj or nil
end

--- Capture the stock star texture once per course so it can be restored.
local function captureOriginal()
    if originalTexture ~= nil then return end
    local cur = readUDS(PROP_REAL_STARS_TEXTURE)
    if isValidObj(cur) then originalTexture = cur end
end

--- Apply the HD (or default) real-stars configuration to UDS.
--- @return boolean success
--- The actual engine work: resolve the asset + write UDS properties.
--- MUST run on the game thread (see applyStars).
local function applyStarsOnGameThread()
    local uds = getUDS()
    if not uds then return end

    captureOriginal()

    -- Enable high-res real stars
    writeUDS(PROP_SIMULATE_REAL_STARS, true)

    -- Swap in the HD texture if requested and resolvable
    if hdStars then
        local tex = loadAsset(texturePath)
        if tex then
            writeUDS(PROP_REAL_STARS_TEXTURE, tex)
        else
            Log.Warn(MODULE, "HD star texture not found - using current texture", {path = texturePath})
        end
    end

    if tiling ~= nil then writeUDS(PROP_STARS_TILING, tiling) end
    if intensity ~= nil then writeUDS(PROP_STARS_INTENSITY, intensity) end

    -- Push changes through UDS
    writeUDS(PROP_REFRESH, true)
end

local function applyStars()
    if not getUDS() then return false end

    -- CRITICAL: resolving an asset (StaticFindObject/StaticLoadObject) and writing
    -- an OBJECT-typed UProperty (the star texture) must happen on the game thread.
    -- TXR's module Setup/Tick run on UE4SS's async LoopAsync thread; doing this
    -- off-thread during course BeginPlay corrupts UE4SS reflection state and
    -- crashes the game with 0xC0000005. This was the course-load crash. Marshal it.
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(applyStarsOnGameThread) end)
    else
        applyStarsOnGameThread()
    end
    return true
end

-- ============== PUBLIC API ==============

--- Initialize stars module
--- @return boolean success
function Stars.Init()
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end

    local cfg = Config.Stars
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.HDStars ~= nil then hdStars = cfg.HDStars end
        if cfg.TexturePath then texturePath = cfg.TexturePath end
        if cfg.Tiling ~= nil then tiling = cfg.Tiling end
        if cfg.Intensity ~= nil then intensity = cfg.Intensity end
    end

    isInitialized = true
    State.SetModuleStatus("stars", true)
    Log.Info(MODULE, "Initializing stars module", {enabled = enabled, hd = hdStars})
    return true
end

--- Apply stars once actors are ready (called per course load from main).
function Stars.Setup()
    if not isInitialized then return end
    if not enabled then return end

    local actors = getActors()
    if not actors or not actors.IsOnCourse() then return end

    -- Fresh course: re-capture the stock texture for this UDS instance
    originalTexture = nil
    applied = applyStars()
    if applied then
        Log.Info(MODULE, "Stars applied", {hd = hdStars, tiling = tiling})
    end
end

--- Force the HD texture on
--- @return boolean success
function Stars.UseHD()
    hdStars = true
    local ok = applyStars()
    Log.Info(MODULE, "Switched to HD stars", {applied = ok})
    return ok
end

--- Restore the stock star texture (keeps real stars enabled)
--- @return boolean success
function Stars.UseOriginal()
    if not isValidObj(originalTexture) then
        Log.Warn(MODULE, "No original star texture captured - cannot restore")
        return false
    end
    writeUDS(PROP_REAL_STARS_TEXTURE, originalTexture)
    writeUDS(PROP_SIMULATE_REAL_STARS, true)
    writeUDS(PROP_REFRESH, true)
    hdStars = false
    Log.Info(MODULE, "Restored original star texture")
    return true
end

--- Toggle between HD and stock textures
--- @return boolean success
function Stars.Toggle()
    local cur = readUDS(PROP_REAL_STARS_TEXTURE)
    local hd = loadAsset(texturePath)
    if hd and cur == hd and isValidObj(originalTexture) then
        return Stars.UseOriginal()
    end
    return Stars.UseHD()
end

--- Set star intensity at runtime
--- @param value number
--- @return boolean success
function Stars.SetIntensity(value)
    intensity = value
    local ok = writeUDS(PROP_STARS_INTENSITY, value)
    if ok then writeUDS(PROP_REFRESH, true) end
    Log.Info(MODULE, "Stars intensity set", {intensity = value, applied = ok})
    return ok
end

--- Get status for debugging
--- @return table
function Stars.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        hdStars = hdStars,
        applied = applied,
        tiling = tiling,
        intensity = intensity,
        hasOriginalCaptured = isValidObj(originalTexture),
    }
end

--- Check if initialized
--- @return boolean
function Stars.IsInitialized()
    return isInitialized
end

return Stars
