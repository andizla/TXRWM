-- TXR Weather Mod v3.0
-- systems/vignette.lua
-- Optional: hide TXR's in-game HUD vignette (the dark corner frame) for
-- screenshots / photo-mode driving. A UI-widget toggle on TXR's own HUD
-- (WBP_InGame_Hud_C, child WBP_Com_Vignette_Frame), not a UDS/UDW post-process
-- effect, and no game files change. Default off (it removes a vanilla HUD
-- element). The HUD widget tree is rebuilt on player-controller restarts
-- (course load, PA exit), so the state is re-asserted on the ClientRestart hook
-- and by a throttled periodic re-assert from the main tick (a cheap no-op when
-- the HUD is absent).

local Vignette = {}

local Log = require("core.logging")
local Config = require("config")

local MODULE = "Vignette"

local PROP_FRAME = "WBP_Com_Vignette_Frame"  -- child widget on WBP_InGame_Hud_C

local initialized = false
local enabled = false      -- module active at all
local hideVignette = true  -- when active, true = hide the vignette
local lastReassert = 0.0
local REASSERT_INTERVAL = 5.0  -- seconds between periodic re-asserts (the
                               -- ClientRestart hook covers HUD rebuilds)
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

--- Apply the hide/show state to the frame widget. Returns true if applied.
--- Runs async (GT-marshalling was tried 2026-07-27 and reverted the same day:
--- object-array walks on the game thread hitch frames); the teardown gate
--- plus pcall is the protection.
local function applyOnce()
    if teardownActive() then return false end
    local v = getFrame()
    if not v then return false end

    -- Already in the wanted state: skip the three UMG calls
    local vis = nil
    pcall(function() if v.GetVisibility then vis = v:GetVisibility() end end)
    if vis == (hideVignette and 2 or 0) then return true end

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
    -- Course/PA only: the driving HUD exists only there. The ungated version
    -- swept FindFirstOf widgets from the async tick in garage/menu worlds every
    -- 1.5s, a no-op with full exposure to the map-open teardown AV (2026-07-21
    -- dump verdict). The ClientRestart hook still covers controller restarts.
    local actors = getActors()
    if not actors then return end
    local tag = actors.GetWorldTag and actors.GetWorldTag()
    if tag ~= "course" and not (actors.IsInPAScene and actors.IsInPAScene()) then return end
    local now = os.clock()
    if (now - lastReassert) < REASSERT_INTERVAL then return end
    lastReassert = now
    applyOnce()
end

return Vignette
