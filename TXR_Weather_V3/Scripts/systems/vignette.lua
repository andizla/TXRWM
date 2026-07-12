-- TXR Weather Mod v3.0
-- systems/vignette.lua
-- Optional: hide TXR's in-game HUD vignette (the dark corner-darkening frame) for a
-- cleaner, more photographic look, useful for screenshots / photo-mode driving.
--
-- This is a pure UI-widget toggle on TXR's OWN HUD (WBP_InGame_Hud_C ->
-- WBP_Com_Vignette_Frame), NOT a UDS/UDW post-process effect, so it works reliably.
-- It does not add or modify any game files. Default OFF (it removes a vanilla HUD
-- element, so it's opt-in). Ported/rewritten from the 1.34 monolith's uds_vignette.
--
-- The HUD widget tree is rebuilt on player-controller restarts (course load, PA
-- exit, etc.), so we re-assert on the ClientRestart hook AND with a light periodic
-- re-assert from the main tick (throttled). Re-asserting when the HUD isn't present
-- is a cheap no-op.

local Vignette = {}

local Log = require("core.logging")
local Config = require("config")

local MODULE = "Vignette"

local PROP_FRAME = "WBP_Com_Vignette_Frame"  -- child widget on WBP_InGame_Hud_C

local initialized = false
local enabled = false      -- module active at all
local hideVignette = true  -- when active, true = hide the vignette
local lastReassert = 0.0
local REASSERT_INTERVAL = 1.5  -- seconds between periodic re-asserts
local lastLoggedState = nil
local hookRegistered = false

-- Lazy-loaded to avoid circular requires
local Actors = nil
local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

--- True while a map teardown is in progress: no object probes or widget calls
--- then (an object search against a dying world can be an uncatchable access
--- violation; same gating as audio/photomode/tuning)
local function teardownActive()
    local actors = getActors()
    if actors and actors.IsDiscoverySuspended then
        return actors.IsDiscoverySuspended()
    end
    return false
end

local function getHud()
    local hud = nil
    pcall(function() hud = FindFirstOf("WBP_InGame_Hud_C") end)
    if hud and hud.IsValid and hud:IsValid() then return hud end
    return nil
end

--- Resolve the vignette frame widget: prefer the HUD's named child, fall back to a
--- direct class search.
local function getFrame()
    local hud = getHud()
    local v = nil
    if hud then pcall(function() v = hud[PROP_FRAME] end) end
    if v and v.IsValid and v:IsValid() then return v end

    pcall(function() v = FindFirstOf("WBP_Com_Vignette_Frame_C") end)
    if v and v.IsValid and v:IsValid() then return v end
    return nil
end

--- Apply the current hide/show state to the frame widget. Returns true if applied.
local function applyOnce()
    if teardownActive() then return false end
    local v = getFrame()
    if not v then return false end

    if hideVignette then
        pcall(function() if v.SetRenderOpacity then v:SetRenderOpacity(0.0) end end)
        pcall(function() if v.SetVisibility then v:SetVisibility(2) end end)   -- ESlateVisibility::Collapsed
        pcall(function() if v.SetIsEnabled then v:SetIsEnabled(false) end end)
    else
        pcall(function() if v.SetRenderOpacity then v:SetRenderOpacity(1.0) end end)
        pcall(function() if v.SetVisibility then v:SetVisibility(0) end end)   -- ESlateVisibility::Visible
        pcall(function() if v.SetIsEnabled then v:SetIsEnabled(true) end end)
    end
    return true
end

local function reassert()
    if applyOnce() then
        local state = hideVignette and "HIDDEN" or "SHOWN"
        if state ~= lastLoggedState then
            Log.Info(MODULE, "Vignette " .. state)
            lastLoggedState = state
        end
    end
end

-- ============== PUBLIC API ==============

function Vignette.Init()
    if initialized then return true end
    local cfg = Config.Vignette
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.Hide ~= nil then hideVignette = cfg.Hide end
    end
    initialized = true
    Log.Info(MODULE, "Initializing vignette module", { enabled = enabled, hide = hideVignette })

    if not enabled then return true end

    -- Re-assert when the player controller restarts (HUD widgets get rebuilt).
    if not hookRegistered and type(RegisterHook) == "function" then
        local ok = pcall(function()
            RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
                -- Small delay lets the widget tree finish constructing before we poke it.
                if type(LoopAsync) == "function" then
                    LoopAsync(150, function() reassert(); return true end)
                else
                    reassert()
                end
            end)
        end)
        hookRegistered = ok
    end

    return true
end

--- Light periodic re-assert from the main loop (throttled). Covers late HUD loads
--- the ClientRestart hook might miss. No-op when the HUD isn't present.
function Vignette.Tick()
    if not initialized or not enabled then return end
    local now = os.clock()
    if (now - lastReassert) < REASSERT_INTERVAL then return end
    lastReassert = now
    applyOnce()
end

function Vignette.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        hide = hideVignette,
        hudPresent = getHud() ~= nil,
    }
end

return Vignette
