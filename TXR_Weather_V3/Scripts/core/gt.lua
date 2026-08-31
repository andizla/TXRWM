-- TXR Weather Mod v3.0
-- core/gt.lua
-- Single-flight game-thread marshal queue: THE mitigation for the
-- "[Lua::Registry::get_function_ref] Ref was not function" family
-- (silent engine-tick hook removal = dead pump, or a fatal abort).
--
-- WHY: UE4SS shares ONE Lua registry across the main/async/hook
-- states. Every raw ExecuteInGameThread call luaL_ref's its callback
-- on the CALLER's thread while the game-thread drain get_function_ref
-- + luaL_unref's it with no lock covering the pair (LuaMod.cpp
-- 3067/2934). An async ref interleaving a game-thread unref can
-- double-hand a registry freelist slot; the next drain then finds a
-- non-function and UE4SS removes its engine-tick hook (or aborts).
-- The mod rolled those dice on every marshal (~38 call sites, worst
-- bursts at photomode entry / ClientRestart / world swaps = exactly
-- where the 2026-08 deaths clustered, here AND on a tester's stock
-- 3.9.0).
--
-- THE FIX: modules never call ExecuteInGameThread. GT.Run(fn) pushes
-- fn onto a plain Lua table (single VM op, atomic under UE4SS's
-- global Lua lock, NO registry refs). The async main loop calls
-- GT.PumpTick() at 8 Hz; when work exists and no pump action is in
-- flight it arms ONE ExecuteInGameThread whose body drains the whole
-- queue on the game thread. Idle = zero refs; continuous load = at
-- most ~8 refs/sec (was 5-15+); never two registry transactions in
-- flight.
--
-- HISTORY: distilled from the 2026-07-16 cloud experiment's
-- core/gt.lua. That bundle was reverted for MAJOR PERFORMANCE issues
-- (the 5fps discovery): it ran the ENTIRE mod tick on the game
-- thread (30 ms FindAllOf blocks on the frame) driven by a PER-FRAME
-- BP-tick hook (Lua dispatch every frame). BOTH halves are dropped
-- here: module ticks stay async, the pump arms at 8 Hz max and only
-- when work exists, and the game thread runs exactly the closures it
-- already ran (same bodies, same thread, batched submission) =
-- performance-neutral by construction.
--
-- A/B LEVER: Config.GT.SingleFlight = false restores raw per-call
-- ExecuteInGameThread passthrough, so the crash-rate claim stays
-- testable in the field.
--
-- THREADING CONTRACT:
--   queue                 : pushed from any thread, swapped+drained on GT
--   afterJobs/nextAfterAt : mutated on GT only (async inserts ride the
--                           queue); async READS nextAfterAt (a plain
--                           number, atomic under the global Lua lock)
--   pumpInFlight/pumpArmedAt : async arms, the GT action clears
--   inScope / lastDriveAt : GT writes, async reads

local GT = {}

local Log = require("core.logging")
local Config = require("config")

local MODULE = "GT"

local singleFlight = true      -- Config.GT.SingleFlight (read at first use)
local configRead = false

local queue = {}               -- marshalled jobs (any thread -> GT)
local afterJobs = {}           -- {at, fn}: GT-owned delayed jobs
local nextAfterAt = math.huge  -- soonest afterJobs at (GT writes, async reads)

local inScope = false
local lastDriveAt = 0.0
local pumpInFlight = false
local pumpArmedAt = 0.0

-- A queued action is never dropped by UE4SS (erased only when run), so
-- a long-pending pump means the game thread is stalled OR the engine-
-- tick hook was removed (the failure this module mitigates). Re-arming
-- early risks two live registry transactions: re-arm ONCE per 30s and
-- say so (main's pump watchdog flags the dead pump separately).
local PUMP_WEDGE_SEC = 30.0
-- Never arm hot on the heels of a finished Drive: the engine-side
-- drain luaL_unref's the previous action just AFTER our Lua returns;
-- one holdoff keeps our next luaL_ref clear of that tail.
local PUMP_ARM_HOLDOFF = 0.1

local QUEUE_CAP = 400          -- runaway backstop; drops oldest, warns
local dropWarned = 0.0

local function readConfig()
    configRead = true
    local c = Config.GT
    if c and c.SingleFlight ~= nil then singleFlight = c.SingleFlight end
    if not singleFlight then
        Log.Warn(MODULE, "SingleFlight OFF: raw per-call marshals (A/B mode)")
    end
end

local function recomputeNextAfter()
    local soonest = math.huge
    for i = 1, #afterJobs do
        if afterJobs[i].at < soonest then soonest = afterJobs[i].at end
    end
    nextAfterAt = soonest
end

--- Run fn on the game thread. Inline when already in GT scope (a job
--- enqueueing from inside the drain; also dodges UE4SS issue #1180's
--- re-entrant ExecuteInGameThread corruption). Queued otherwise.
--- Replaces every direct ExecuteInGameThread call in the modules.
function GT.Run(fn)
    if type(fn) ~= "function" then return false end
    if not configRead then readConfig() end
    if inScope then
        local ok, err = pcall(fn)
        if not ok then Log.Warn(MODULE, "Inline job error: " .. tostring(err)) end
        return true
    end
    if not singleFlight then
        if type(ExecuteInGameThread) == "function" then
            local ok = pcall(function() ExecuteInGameThread(fn) end)
            return ok
        end
        local ok = pcall(fn)
        return ok
    end
    if #queue >= QUEUE_CAP then
        table.remove(queue, 1)
        local now = os.clock()
        if (now - dropWarned) > 60.0 then
            dropWarned = now
            Log.Warn(MODULE, "Queue over cap: dropping oldest (pump dead or stalled?)")
        end
    end
    queue[#queue + 1] = fn
    return true
end

--- Run fn on the game thread after roughly `seconds`. Replaces
--- ExecuteWithDelay (whose per-call refs are the same hazard).
function GT.After(seconds, fn)
    if type(fn) ~= "function" then return end
    if not configRead then readConfig() end
    if not singleFlight then
        -- A/B mode has no drain loop, so afterJobs inserts would sit
        -- forever: restore the raw pre-queue behavior instead.
        local ms = math.floor((seconds or 0) * 1000 + 0.5)
        if type(ExecuteWithDelay) == "function" then
            pcall(function() ExecuteWithDelay(ms, fn) end)
        else
            pcall(fn)
        end
        return
    end
    local at = os.clock() + (seconds or 0)
    GT.Run(function()
        afterJobs[#afterJobs + 1] = { at = at, fn = fn }
        if at < nextAfterAt then nextAfterAt = at end
    end)
end

--- Drain everything on the game thread. MUST only run there.
function GT.Drive(source)
    if inScope then
        if source == "pump" then pumpInFlight = false end
        return
    end
    inScope = true

    if #queue > 0 then
        local q = queue
        queue = {}
        for i = 1, #q do
            local ok, err = pcall(q[i])
            if not ok then Log.Warn(MODULE, "Queued job error: " .. tostring(err)) end
        end
    end

    if #afterJobs > 0 and os.clock() >= nextAfterAt then
        -- swap FIRST: a job scheduling another GT.After appends to the
        -- fresh table and survives the rebuild
        local due = afterJobs
        afterJobs = {}
        local now = os.clock()
        for i = 1, #due do
            local job = due[i]
            if now >= job.at then
                local ok, err = pcall(job.fn)
                if not ok then Log.Warn(MODULE, "Delayed job error: " .. tostring(err)) end
            else
                afterJobs[#afterJobs + 1] = job
            end
        end
        recomputeNextAfter()
    end

    inScope = false
    -- Stamped at drain END, not start: PUMP_ARM_HOLDOFF must clear the
    -- engine-side unref that trails our RETURN, so a long drain cannot
    -- consume the holdoff before the edge it protects even happens.
    lastDriveAt = os.clock()
    -- release the slot LAST: the async side may only arm the next
    -- action once this one's work is done (its trailing engine-side
    -- unref is covered by PUMP_ARM_HOLDOFF)
    if source == "pump" then
        pumpInFlight = false
    end
end

--- Async-side pump: called from the 8 Hz main loop. Arms at most ONE
--- game-thread action, and only when there is actually work.
function GT.PumpTick()
    if not configRead then readConfig() end
    if not singleFlight then return end
    local now = os.clock()
    if #queue == 0 and now < nextAfterAt then return end
    if pumpInFlight then
        if (now - pumpArmedAt) > PUMP_WEDGE_SEC then
            pumpInFlight = false
            Log.Warn(MODULE, "Pump action pending >30s (engine-tick hook dead"
                .. " or game thread stalled): re-arming once")
        end
        return
    end
    if (now - lastDriveAt) < PUMP_ARM_HOLDOFF then return end
    if type(ExecuteInGameThread) ~= "function" then
        GT.Drive("pump-direct")
        return
    end
    pumpInFlight = true
    pumpArmedAt = now
    local ok = pcall(function()
        ExecuteInGameThread(function()
            GT.Drive("pump")
        end)
    end)
    if not ok then pumpInFlight = false end
end

function GT.GetStatus()
    return {
        singleFlight = singleFlight,
        queued = #queue,
        delayed = #afterJobs,
        pumpInFlight = pumpInFlight,
        lastDriveAgo = os.clock() - lastDriveAt,
    }
end

return GT
