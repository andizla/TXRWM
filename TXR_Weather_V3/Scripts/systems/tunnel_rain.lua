-- TXR Weather Mod v3.0
-- systems/tunnel_rain.lua
-- EXPERIMENT: stop rain leaking into tunnels by changing the channel UDW traces
-- for weather-particle occlusion.
--
-- TXR tunnels have DOUBLE walls: the visible inner wall is visual-only (no
-- collision); the outer wall carries the physical collision. UDW occludes rain by
-- tracing its "Weather Particle Collision Channel" (default Visibility) for a
-- ceiling. If the overhead geometry doesn't block that channel's QUERIES, rain
-- leaks in. Overpasses occlude fine. Hypothesis: trace a channel the tunnel's
-- overhead geometry actually blocks. Pure Lua, no content pak.
--
-- First test (WorldStatic) produced no change in a tunnel (mode confirmed Simple,
-- channel confirmed flipped) -> so we now CYCLE every candidate channel with the
-- keybind, and also push the change onto the live rain component via
-- "Set Shared Weather Particle Parameters" so a stale Niagara param can't mask it.
-- If NO channel occludes, the tunnel has no overhead query collision and the Lua
-- route is dead (fall back to placed occlusion volumes via the content pak).
--
-- Only meaningful when "Particle Collision Mode" = Simple Collision (channel is
-- ignored in Distance Field mode). We read it back so you can confirm.

local TunnelRain = {}

local Log = require("core.logging")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "TunnelRain"

local PROP_MODE     = "Particle Collision Mode"
local PROP_CHANNEL  = "Weather Particle Collision Channel"
local PROP_CEILING  = "Ceiling Check Height"
local PROP_REFRESH  = "Refresh Settings"
local PROP_RAINPART = "Rain Particles"
local FN_SET_SHARED = "Set Shared Weather Particle Parameters"

-- ECollisionChannel byte values (UE5 stock order).
local CHANNELS = {
    WorldStatic = 0, WorldDynamic = 1, Pawn = 2, Visibility = 3,
    Camera = 4, PhysicsBody = 5, Vehicle = 6, Destructible = 7,
}
local CHANNEL_NAME = {}
for k, v in pairs(CHANNELS) do CHANNEL_NAME[v] = k end

-- Best-guess names for Particle Collision Mode (doc order: Simple, DF, None).
local MODE_NAME = { [0] = "Simple", [1] = "DistanceField", [2] = "None" }

-- Order the keybind cycles through. Index 1 = Visibility = the game default ("off").
local CYCLE = { "Visibility", "WorldStatic", "WorldDynamic", "Camera", "Vehicle", "Pawn", "PhysicsBody" }

local SETTLE_TICKS = 24  -- ~3s at 8 Hz before any auto-apply (clears BeginPlay)

local initialized = false
local applied = false
local origChannel = nil
local origCeiling = nil
local cycleIndex = 1
local settleTicks = 0
local autoAppliedThisCourse = false

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function resolveConfigChannel()
    local name = (Config.TunnelRain and Config.TunnelRain.Channel) or "WorldStatic"
    return CHANNELS[name] or CHANNELS.WorldStatic, name
end

local function readback(tag, intendedName)
    local actors = getActors()
    if not actors then return end
    local udw = actors.GetUDW()
    if not udw then return end
    local function rd(p)
        local v = nil
        pcall(function() v = udw[p] end)
        return v
    end
    local mode = rd(PROP_MODE)
    local ch = rd(PROP_CHANNEL)
    local modeN = (type(mode) == "number") and (MODE_NAME[mode] or "?") or "?"
    local chN = (type(ch) == "number") and (CHANNEL_NAME[ch] or "?") or "?"
    Log.Info(MODULE, "Tunnel-rain readback", {
        tag = tag or "set",
        intended = intendedName or "?",
        mode = tostring(mode) .. " (" .. modeN .. ")",
        channel = tostring(ch) .. " (" .. chN .. ")",
        ceiling = tostring(rd(PROP_CEILING)),
    })
end

-- Push shared particle settings (incl. collision channel) onto the live rain
-- Niagara component, so the change reaches already-spawned particles.
local function pushSharedParams(udw)
    local rainParticles = nil
    pcall(function() rainParticles = udw[PROP_RAINPART] end)
    if not rainParticles then return end
    local fn = nil
    pcall(function() fn = udw[FN_SET_SHARED] end)
    if fn then pcall(function() fn(udw, rainParticles) end) end
end

-- Core setter (runs on game thread). Sets channel, optional ceiling, propagates.
local function setChannel(chByte, chName)
    local actors = getActors()
    if not actors then return end
    local udw = actors.GetUDW()
    if not udw then return end

    if origChannel == nil then pcall(function() origChannel = udw[PROP_CHANNEL] end) end
    if origCeiling == nil then pcall(function() origCeiling = udw[PROP_CEILING] end) end

    pcall(function() udw[PROP_CHANNEL] = chByte end)

    local cfg = Config.TunnelRain or {}
    if cfg.CeilingCheckHeight then
        pcall(function() udw[PROP_CEILING] = cfg.CeilingCheckHeight end)
    end

    pushSharedParams(udw)
    if cfg.RefreshAfter ~= false then
        pcall(function() udw[PROP_REFRESH] = true end)
    end

    applied = (chByte ~= CHANNELS.Visibility)
    Log.Info(MODULE, "Set weather particle collision channel", { channel = chName, byte = chByte })
    readback("set", chName)
end

local function onGameThread(fn)
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(fn) end)
    else
        fn()
    end
end

-- ============== PUBLIC API ==============

function TunnelRain.Init()
    if initialized then return true end
    initialized = true
    Log.Info(MODULE, "Initializing tunnel-rain module", {
        enabled = (Config.TunnelRain and Config.TunnelRain.Enabled) == true,
        channel = (Config.TunnelRain or {}).Channel,
    })
    return true
end

--- Apply the config-selected channel (used for auto-apply on course load).
function TunnelRain.Apply()
    local byte, name = resolveConfigChannel()
    onGameThread(function() setChannel(byte, name) end)
    return true
end

--- Restore the original (game default) channel.
function TunnelRain.Revert()
    onGameThread(function()
        local actors = getActors()
        if not actors then return end
        local udw = actors.GetUDW()
        if not udw then return end
        if origChannel ~= nil then pcall(function() udw[PROP_CHANNEL] = origChannel end) end
        if origCeiling ~= nil then pcall(function() udw[PROP_CEILING] = origCeiling end) end
        pushSharedParams(udw)
        if (Config.TunnelRain or {}).RefreshAfter ~= false then
            pcall(function() udw[PROP_REFRESH] = true end)
        end
        applied = false
        Log.Info(MODULE, "Reverted to original channel", { channel = tostring(origChannel) })
        readback("revert", CHANNEL_NAME[origChannel] or "orig")
    end)
    return true
end

--- Keybind handler: advance to the next candidate channel. Returns its name.
--- Sweep all of these in one tunnel pass to see if ANY occludes the rain.
function TunnelRain.Cycle()
    cycleIndex = cycleIndex + 1
    if cycleIndex > #CYCLE then cycleIndex = 1 end
    local name = CYCLE[cycleIndex]
    local byte = CHANNELS[name]
    onGameThread(function() setChannel(byte, name) end)
    return name
end

function TunnelRain.Tick()
    if not initialized then return end
    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        settleTicks = 0
        autoAppliedThisCourse = false
        return
    end
    settleTicks = settleTicks + 1
    local cfg = Config.TunnelRain or {}
    if cfg.Enabled and not autoAppliedThisCourse and settleTicks >= SETTLE_TICKS then
        autoAppliedThisCourse = true
        TunnelRain.Apply()
    end
end

function TunnelRain.GetStatus()
    return { initialized = initialized, applied = applied, channel = CYCLE[cycleIndex] }
end

return TunnelRain
