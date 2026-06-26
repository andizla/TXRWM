-- TXR Weather Mod v3.0
-- core/utils.lua
-- Utility functions for safe operations, validation, and common patterns

local Utils = {}

-- ============== ACTOR/UOBJECT VALIDATION ==============

--- Check if a UObject reference is valid
--- @param obj any The object to check
--- @return boolean
function Utils.IsValidObject(obj)
    if obj == nil then
        return false
    end
    
    -- Check for UE4SS UObject validity
    if type(obj) == "userdata" then
        -- Try calling IsValid if available
        local success, isValid = pcall(function()
            if obj.IsValid then
                return obj:IsValid()
            end
            -- If no IsValid method, assume valid if non-nil userdata
            return true
        end)
        
        if success then
            return isValid
        end
        -- If IsValid call failed, object is likely invalid
        return false
    end
    
    -- Tables and other types - just check non-nil
    return obj ~= nil
end

--- Safely get a property from a UObject
--- @param obj any The object to read from
--- @param propertyName string The property name
--- @param defaultValue any Value to return if property read fails
--- @return any value, boolean success
function Utils.SafeGetProperty(obj, propertyName, defaultValue)
    if not Utils.IsValidObject(obj) then
        return defaultValue, false
    end
    
    local success, value = pcall(function()
        return obj[propertyName]
    end)
    
    if success and value ~= nil then
        return value, true
    end
    
    return defaultValue, false
end

--- Safely set a property on a UObject
--- @param obj any The object to write to
--- @param propertyName string The property name
--- @param value any The value to set
--- @return boolean success
function Utils.SafeSetProperty(obj, propertyName, value)
    if not Utils.IsValidObject(obj) then
        return false
    end
    
    local success, err = pcall(function()
        obj[propertyName] = value
    end)
    
    return success
end

--- Safely get a function reference from a UObject
--- @param obj any The object to read from
--- @param functionName string The function name
--- @return function|nil, boolean success
function Utils.SafeGetFunction(obj, functionName)
    if not Utils.IsValidObject(obj) then
        return nil, false
    end
    
    local success, fn = pcall(function()
        return obj[functionName]
    end)
    
    if not success then
        return nil, false
    end
    
    -- In UE4SS, functions are often userdata that's callable, not Lua functions
    local fnType = type(fn)
    if fnType == "function" then
        return fn, true
    elseif fnType == "userdata" then
        -- UE4SS UFunctions are userdata - assume callable
        return fn, true
    elseif fn ~= nil then
        -- Could be a table with __call metamethod or other callable
        return fn, true
    end
    
    return nil, false
end

-- ============== NUMBER UTILITIES ==============

--- Convert a value to number with fallback default
--- @param value any The value to convert
--- @param default number The default if conversion fails
--- @return number
function Utils.ToNumber(value, default)
    default = default or 0
    if type(value) == "number" then
        return value
    end
    local num = tonumber(value)
    return num or default
end

--- Clamp a number between min and max
--- @param value number The value to clamp
--- @param min number Minimum value
--- @param max number Maximum value
--- @return number
function Utils.Clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

--- Linear interpolation between two values
--- @param a number Start value
--- @param b number End value
--- @param t number Interpolation factor (0-1)
--- @return number
function Utils.Lerp(a, b, t)
    t = Utils.Clamp(t, 0, 1)
    return a + (b - a) * t
end

--- Check if a number is approximately equal to another
--- @param a number First value
--- @param b number Second value
--- @param epsilon number Tolerance (default 0.0001)
--- @return boolean
function Utils.ApproxEqual(a, b, epsilon)
    epsilon = epsilon or 0.0001
    return math.abs(a - b) < epsilon
end

-- ============== STRING UTILITIES ==============

--- Safe tostring that handles nil
--- @param value any The value to convert
--- @return string
function Utils.SafeToString(value)
    if value == nil then
        return "nil"
    end
    local success, str = pcall(tostring, value)
    if success then
        return str
    end
    return "<tostring failed>"
end

--- Truncate a string to max length with ellipsis
--- @param str string The string to truncate
--- @param maxLen number Maximum length
--- @return string
function Utils.Truncate(str, maxLen)
    if type(str) ~= "string" then
        str = Utils.SafeToString(str)
    end
    if #str <= maxLen then
        return str
    end
    return string.sub(str, 1, maxLen - 3) .. "..."
end

--- Format a memory address for logging
--- @param obj any UObject or userdata
--- @return string
function Utils.FormatAddress(obj)
    if obj == nil then
        return "nil"
    end
    local str = Utils.SafeToString(obj)
    -- Try to extract address from UE4SS object string representation
    local addr = str:match("0x%x+") or str:match("%x%x%x%x%x%x%x%x+")
    return addr or str
end

-- ============== TABLE UTILITIES ==============

--- Get table keys as an array
--- @param t table The table
--- @return table Array of keys
function Utils.Keys(t)
    local keys = {}
    if type(t) == "table" then
        for k, _ in pairs(t) do
            table.insert(keys, k)
        end
    end
    return keys
end

-- ============== TIME UTILITIES ==============

--- Get current time in seconds (high resolution if available)
--- @return number
function Utils.GetTime()
    -- os.clock() gives CPU time, os.time() gives wall time
    -- For game timing, we want wall time
    return os.clock()  -- Returns seconds with subsecond precision
end

--- Calculate delta time between two timestamps
--- @param startTime number Start time from GetTime()
--- @param endTime number|nil End time (default: current time)
--- @return number Delta in seconds
function Utils.DeltaTime(startTime, endTime)
    endTime = endTime or Utils.GetTime()
    return endTime - startTime
end

-- ============== ANIMATION/SMOOTHING ==============

--- Smooth step interpolation (cubic Hermite)
--- @param t number Input value (0-1)
--- @return number Smoothed value (0-1)
function Utils.SmoothStep(t)
    t = Utils.Clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

--- Exponential smoothing (frame-rate independent)
--- @param current number Current value
--- @param target number Target value
--- @param smoothTime number Time to reach ~63% of target (seconds)
--- @param dt number Delta time (seconds)
--- @return number Smoothed value
function Utils.ExpSmooth(current, target, smoothTime, dt)
    if smoothTime <= 0 then
        return target
    end
    local factor = 1 - math.exp(-dt / smoothTime)
    return current + (target - current) * factor
end

-- ============== TIME-BASED FACTORS ==============

--- Calculate dawn/dusk blend factor
--- @param tod number Time of day (0-2400)
--- @param dawnStart number Dawn window start
--- @param dawnEnd number Dawn window end
--- @param duskStart number Dusk window start
--- @param duskEnd number Dusk window end
--- @return number Factor 0-1 (0 = not in window, 1 = peak of window)
function Utils.DawnDuskFactor(tod, dawnStart, dawnEnd, duskStart, duskEnd)
    -- Dawn window
    if tod >= dawnStart and tod <= dawnEnd then
        local mid = (dawnStart + dawnEnd) / 2
        local halfWidth = (dawnEnd - dawnStart) / 2
        if halfWidth <= 0 then return 1 end
        local dist = math.abs(tod - mid) / halfWidth
        return Utils.Clamp(1 - dist, 0, 1)
    end
    
    -- Dusk window
    if tod >= duskStart and tod <= duskEnd then
        local mid = (duskStart + duskEnd) / 2
        local halfWidth = (duskEnd - duskStart) / 2
        if halfWidth <= 0 then return 1 end
        local dist = math.abs(tod - mid) / halfWidth
        return Utils.Clamp(1 - dist, 0, 1)
    end
    
    return 0
end

-- ============== RANDOM SELECTION ==============

--- Weighted random selection from a pool
--- @param pool table Array of {name=string, weight=number}
--- @return string|nil Selected name or nil if empty
function Utils.WeightedPick(pool)
    if not pool or #pool == 0 then
        return nil
    end
    
    -- Calculate total weight
    local total = 0
    for _, item in ipairs(pool) do
        total = total + (item.weight or 1)
    end
    
    if total <= 0 then
        -- Fall back to uniform random
        return pool[math.random(#pool)].name
    end
    
    -- Pick random point
    local r = math.random() * total
    local cumulative = 0
    
    for _, item in ipairs(pool) do
        cumulative = cumulative + (item.weight or 1)
        if r <= cumulative then
            return item.name
        end
    end
    
    -- Fallback (shouldn't reach here)
    return pool[#pool].name
end

return Utils
