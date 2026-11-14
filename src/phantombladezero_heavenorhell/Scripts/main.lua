-- Heaven or Hell for Phantom Blade Zero.
--
-- The player's hits kill only within WindowMs after a timed parry or a dodge that makes an attack miss (also the
-- red-light perfect dodge and the blue-light parry); every other hit of the player deals about NormalDamage; with
-- EnemyOneShot, enemy hits kill the player at once. Sha-Chi stays the game's. How: see "The damage change" below
-- (the player's attribute values, written directly every WATCH_MS).
--
-- The triggers (tested in Witch Time): the dodge ability BP_PlayerDodge_Base_C (its HitDodge event handler and
-- OnEvadeDamage), the red-light perfect dodge BP_PlayerPerfectDodge_Base_C (K2_ActivateAbility) and the parry ability
-- BP_StanceAction_Base_Player_C ("On Impact", its Deflect.Result: Normal = block, Perfect = timed parry). The
-- Blueprint classes load with the player's abilities: the mod looks for them at start, after each map load and every
-- CHECK_INTERVAL_MS while one is missing (a search by name costs a few milliseconds), and keeps what it found.
--
-- LogHits (for tests) logs the triggers and the attribute writes, and reads the health of the player and of the
-- enemy of the last trigger every WATCH_MS (each change with the time since the trigger), the damage attributes once
-- per class,
-- and the hit, damage and death events sent through AbilitySystemBlueprintLibrary:SendGameplayEventToActor. The hooks
-- APBZCharacter:OnDamage, UAT_WaitReceiveDamage:OnDamageReceived and
-- UGA_DamageModificationBase:OnDamagePreTakeEventReceived never fired in the tests of 1.0 and 1.1 (the game calls
-- them from C++); they stay as log hooks.
--
-- Settings: the player edits Scripts\config.lua. The mod reads it at start and again every CONFIG_INTERVAL_MS (1.7),
-- so a change shows without a restart; a broken or half-saved file keeps the last settings. A part that a change turns
-- off gives the player's attribute values back (GiveBack). DEFAULTS holds every setting with its default. A player
-- (or a mod manager) keeps their config.lua across updates, so a new main.lua can meet an older file: a setting that
-- the file lacks, or has with another type, keeps its default, and the log says so. Read a setting only from
-- Settings, never as `config.X or default`: for a true/false setting, `false or true` is true.
--
-- 1.7: every loop runs on the game thread (LoopInGameThreadWithDelay; the older LoopAsync ran its callback on a second
-- thread beside the hooks: Witch Time's crash lesson of 2026-10-31), config.lua is read live, and the
-- values the mod writes are given back when a setting turns their part off.

local UEHelpers = require("UEHelpers")

local MOD_NAME = "Heaven or Hell"
local VERSION = "1.7"
local CHECK_INTERVAL_MS = 2000
local CONFIG_INTERVAL_MS = 5000
-- Log at most this many error lines in total.
local MAX_ERROR_LOGS = 5
-- Log at most this many LogHits lines per game start.
local MAX_HIT_LOGS = 600
-- Log at most this many sent gameplay events per game start.
local MAX_EVENT_LOGS = 80
-- The health watch: how often (ms) and how long after a trigger the enemy's health is read (real seconds).
local WATCH_MS = 50
local WATCH_SECONDS = 3.0

local DODGE_CLASS = "/PBZDeflectSystem/Abilities/BP_PlayerDodge_Base.BP_PlayerDodge_Base_C"
local EVADE_EVENT_FUNCTION = "EventReceived_DE0795E84ADED85523B251A711345C31"
local EVADE_EVENT_TAG = "GameplayEvent.Actor.HitDodge.Target"
local PERFECT_DODGE_CLASS = "/PBZDeflectSystem/Abilities/BP_PlayerPerfectDodge_Base.BP_PlayerPerfectDodge_Base_C"
local PARRY_CLASS = "/PBZDeflectSystem/Abilities/BP_StanceAction_Base_Player.BP_StanceAction_Base_Player_C"
local CHARACTER_CLASS = "/Script/ProjectPBZ.PBZCharacter"
local RECEIVE_DAMAGE_TASK_CLASS = "/Script/ProjectPBZ.AT_WaitReceiveDamage"
local DAMAGE_MODIFICATION_CLASS = "/Script/PBZCombatAsset.GA_DamageModificationBase"
local ABILITY_LIBRARY_CLASS = "/Script/GameplayAbilities.AbilitySystemBlueprintLibrary"

-- The parry results that open the window: the timed parry, and (assumed) the blue-light parry with its counter. A
-- block (Deflect.Result.Normal) does not (the user, 2026-10-29).
local PARRY_RESULTS = {
    ["Deflect.Result.Perfect"] = true,
    ["Deflect.Result.PerfectCounter"] = true,
}

-- Every setting with its default; config.lua ships the same names and values (tests\test_main.py checks it).
local DEFAULTS = {
    Enable = true,
    WindowMs = 1200,
    NormalDamage = 1,
    EnemyOneShot = true,
    LogHits = false,
}

-- Number settings outside these limits use their default.
local LIMITS = {
    WindowMs = { 50, 5000 },
    NormalDamage = { 0, 1000000 },
}

local errors = 0
local hitLogs = 0

local function Log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local function LogError(message)
    errors = errors + 1
    if errors <= MAX_ERROR_LOGS then
        Log(message)
    end
end

local function CopyDefaults()
    local settings = {}
    for name, value in pairs(DEFAULTS) do
        settings[name] = value
    end
    return settings
end

-- Lua's line number and reason, without the chunk name.
local function Reason(message)
    message = tostring(message)
    local line, reason = message:match("config%.lua:(%d+): ([^\n]*)")
    return line and ("line " .. line .. ": " .. reason) or (message:gsub("%s*\n%s*", " "))
end

-- DEFAULTS with the values of config.lua's text over them; nil and the reason when the text is not a usable file
-- (1.7: from the file's text, so it can be read again; require would keep the first result).
local function ParseConfig(text)
    local chunk, problem = load(text, "=config.lua", "t", {})
    if not chunk then
        return nil, "config.lua not read (" .. Reason(problem) .. ")"
    end
    local ok, config = pcall(chunk)
    if not ok then
        return nil, "config.lua not read (" .. Reason(config) .. ")"
    end
    if type(config) ~= "table" then
        return nil, "config.lua does not return a table"
    end
    local settings = CopyDefaults()
    for name, value in pairs(config) do
        local default = DEFAULTS[name]
        if default == nil then
            Log("config.lua: unknown setting " .. tostring(name) .. " ignored.")
        elseif type(value) ~= type(default) then
            Log(string.format("config.lua: %s must be a %s; the default %s is used.", name, type(default),
                tostring(default)))
        else
            local limit = LIMITS[name]
            if limit and (value ~= value or value < limit[1] or value > limit[2]) then
                Log(string.format("config.lua: %s must be from %s to %s; the default %s is used.", name,
                    tostring(limit[1]), tostring(limit[2]), tostring(default)))
            else
                settings[name] = value
            end
        end
    end
    return settings
end

-- One line for the log: every setting, sorted by name.
local function Describe(settings)
    local names = {}
    for name in pairs(settings) do
        names[#names + 1] = name
    end
    table.sort(names)
    local parts = {}
    for i, name in ipairs(names) do
        parts[i] = name .. "=" .. tostring(settings[name])
    end
    return table.concat(parts, ", ")
end

local Settings = {}
local configPath = nil
-- The text of the last read; false: no file at the last read; nil: not read yet.
local configText = nil

-- Reads config.lua when its text changed since the last read. At start, a missing or broken file means the defaults;
-- later, a broken file keeps the last settings (a half-saved file), and a missing one means the defaults.
local function ReadConfig()
    local atStart = configText == nil
    configPath = configPath or package.searchpath("config", package.path)
    local text = false
    if configPath then
        local file = io.open(configPath, "rb")
        if file then
            text = file:read("a") or false
            file:close()
        end
    end
    if text == configText then
        return
    end
    configText = text
    local settings, problem
    if text == false then
        settings, problem = CopyDefaults(), nil
        Log("No config.lua; every setting uses its default.")
    else
        settings, problem = ParseConfig(text)
    end
    if not settings then
        if atStart then
            Log(problem .. "; every setting uses its default.")
            settings = CopyDefaults()
        else
            Log(problem .. "; the last settings stay.")
            return
        end
    end
    local line = Describe(settings)
    if atStart or line ~= Describe(Settings) then
        Log("Settings: " .. line)
    end
    if not atStart and settings.Enable ~= Settings.Enable then
        Log(settings.Enable and "Enable = true: the mod works again." or
            "Enable = false: the game's values are back; the mod waits until it is true.")
    end
    Settings = settings
end

Log(VERSION .. " loaded.")
Settings = CopyDefaults()
local read, readProblem = pcall(ReadConfig)
if not read then
    LogError("Error while reading config.lua: " .. tostring(readProblem))
end
if not Settings.Enable then
    Log("Enable = false in config.lua: the mod does nothing until it is true.")
end

-- Real time in seconds (wall time on Windows).
local function Now()
    return os.clock()
end

local function LogHit(message)
    if not (Settings.Enable and Settings.LogHits) then
        return
    end
    hitLogs = hitLogs + 1
    if hitLogs <= MAX_HIT_LOGS then
        Log(string.format("%.3f %s", Now(), message))
    elseif hitLogs == MAX_HIT_LOGS + 1 then
        Log("LogHits: " .. MAX_HIT_LOGS .. " lines reached; no more until the next game start.")
    end
end

local function Valid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

local function ClassName(object)
    local ok, name = pcall(function()
        return object:GetClass():GetFName():ToString()
    end)
    return ok and name or "?"
end

-- context and the parameters of a hook are UE4SS RemoteUnrealParam values: :get() gives the value.
local function Get(param)
    local ok, value = pcall(function()
        return param:get()
    end)
    if ok then
        return value
    end
    return nil
end

local controller = nil

local function ControlledPawn()
    if not Valid(controller) then
        controller = UEHelpers.GetPlayerController()
    end
    local pawn = Valid(controller) and controller.Pawn or nil
    return Valid(pawn) and pawn or nil
end

local function IsPlayer(object)
    local pawn = ControlledPawn()
    local ok, same = pcall(function()
        return pawn ~= nil and object:GetAddress() == pawn:GetAddress()
    end)
    return ok and same
end

-- "health 120.0 / 850.0 (base 120.0)" of a character's AttributeSetBase.
local function HealthText(character)
    local ok, text = pcall(function()
        local set = character.AttributeSetBase
        return string.format("health %.1f / %.1f (base %.1f)", set.Health.CurrentValue, set.Health_Max.CurrentValue,
            set.Health.BaseValue)
    end)
    return ok and text or "health ?"
end

-- The tags of a FGameplayTagContainer parameter, at most four.
local function TagsText(container)
    local ok, text = pcall(function()
        local names = {}
        container:get().GameplayTags:ForEach(function(index, tag)
            if #names < 4 then
                names[#names + 1] = tag:get().TagName:ToString()
            end
        end)
        return table.concat(names, ", ")
    end)
    return ok and text or "?"
end

-- The damage change (1.3). No hook sees a single hit (tests of 1.0 and 1.1), so the mod writes the player's
-- attributes directly into the attribute set: CurrentValue only, never BaseValue, so the game's own recalculation
-- brings the real values back as soon as the mod stops writing. 1.2 used the game's AttributeUtils.AddAttributeBuff
-- with an FGameplayAttribute borrowed from the damage calculator: the game crashed in its own code at the first call
-- (reading null + 0x10; UE4SS does not pass the struct's field path), so the mod calls no game function that takes
-- an FGameplayAttribute.
--   * outside the window: Attack = NormalDamage (when it is below the base Attack), so a hit deals about NormalDamage
--     times the move's own factor (0.2 to 2.25 in the test of 1.1); Sha-Chi damage uses ShachiAttack and stays;
--   * on a trigger: Attack = KILL_ATTACK for WindowMs of real time (a new trigger extends the window);
--   * EnemyOneShot: TakenVulnerabilityMultiplier_<type> = base x ONE_SHOT_FACTOR for every health damage type.
-- The game recalculates an attribute's CurrentValue when an effect on it changes, so the fast loop (every WATCH_MS)
-- writes the values again when they differ.
local KILL_ATTACK = 10000000
local ONE_SHOT_FACTOR = 1000
local HEALTH_TYPES = { "Physical", "PhysicalSharp", "PhysicalBlunt", "Elemental", "Fire", "Toxin", "Ice", "Aqua",
    "Lightning", "Blood", "Chaos" }
-- Per state (normal, window), log only the first few rewrites; the window's end line gives the count.
local MAX_REWRITE_LOGS = 3

-- The red-light perfect dodge (1.5): the game's own slow-down and the dodge move come first, its counter attack hit
-- 1.6 to 1.7 s after the trigger (test of 1.3), after any short window. So the window stays open while the game's
-- perfect-dodge ability runs (K2_ActivateAbility to K2_OnEndAbility) and WindowMs after its end; when the end never
-- comes, it closes RED_MAX_SECONDS after the start.
local RED_MAX_SECONDS = 6

local windowUntil = 0        -- Now() when the window ends
local redUntil = 0           -- Now() until a running red-light perfect dodge keeps the window open (its fallback end)
local windowRewrites = 0     -- rewrites of Attack in the running window
local normalRewrites = 0     -- rewrites outside the window since the start

-- Current and base value of an attribute of a character.
local function AttributeValues(character, name)
    local ok, current, base = pcall(function()
        local data = character.AttributeSetBase[name]
        return data.CurrentValue, data.BaseValue
    end)
    if ok then
        return current, base
    end
    return nil, nil
end

local function Near(a, b)
    return math.abs(a - b) <= math.max(0.000001, math.abs(b) * 0.000001)
end

-- The attributes the mod wrote on the player's pawn (1.7): for each, the value it wrote last (mine) and the game's own
-- value (game), taken at the first write and again whenever the game recalculated the value since the mod's last
-- write. A new pawn (a map load, a respawn) starts a new list: its values are the game's.
local written = { pawn = nil, values = {} }

local function WrittenOf(character)
    local address = character:GetAddress()
    if written.pawn ~= address then
        written.pawn, written.values = address, {}
    end
    return written.values
end

-- Writes CurrentValue when it differs; the old value, or nil when nothing was written.
local function WriteAttribute(character, name, value)
    local ok, old = pcall(function()
        local values = WrittenOf(character)
        local data = character.AttributeSetBase[name]
        local current = data.CurrentValue
        local entry = values[name]
        if entry == nil or not Near(current, entry.mine) then
            entry = { mine = current, game = current }
            values[name] = entry
        end
        if Near(current, value) then
            return nil
        end
        data.CurrentValue = value
        entry.mine = value
        return current
    end)
    return ok and old or nil
end

-- Gives an attribute back (1.7): the game's own value, while the value is still the one the mod wrote (else the game
-- has recalculated it already). Nothing when the mod has not written it.
local function GiveBack(character, name)
    pcall(function()
        local values = WrittenOf(character)
        local entry = values[name]
        if entry == nil then
            return
        end
        values[name] = nil
        local data = character.AttributeSetBase[name]
        if Near(data.CurrentValue, entry.mine) then
            data.CurrentValue = entry.game
        end
    end)
end

local function GiveBackAll(character)
    local names = {}
    for name in pairs(WrittenOf(character)) do
        names[#names + 1] = name
    end
    for _, name in ipairs(names) do
        GiveBack(character, name)
    end
end

local windowWasOpen = false

local function KeepAttributes()
    local pawn = ControlledPawn()
    if pawn == nil then
        return
    end
    if not Settings.Enable then
        -- 1.7: switched off: no window, and the game's own values back.
        windowUntil, redUntil, windowWasOpen = 0, 0, false
        GiveBackAll(pawn)
        return
    end
    if redUntil > 0 and Now() >= redUntil then
        redUntil = 0
        LogHit(string.format("red-light perfect dodge: no end seen within %d s; the window closes", RED_MAX_SECONDS))
    end
    local open = Now() < windowUntil or redUntil > 0
    if windowWasOpen and not open then
        LogHit(string.format("window closed (Attack was written again %d times while it was open)", windowRewrites))
    end
    windowWasOpen = open
    local _, attackBase = AttributeValues(pawn, "Attack")
    local desired = nil
    if open then
        desired = KILL_ATTACK
    elseif attackBase ~= nil and Settings.NormalDamage < attackBase then
        desired = Settings.NormalDamage
    end
    if desired ~= nil then
        local old = WriteAttribute(pawn, "Attack", desired)
        if old ~= nil then
            if open then
                windowRewrites = windowRewrites + 1
            else
                normalRewrites = normalRewrites + 1
                if normalRewrites <= MAX_REWRITE_LOGS then
                    LogHit(string.format("Attack %.4g -> %.4g (base %.4g): about %s damage per hit outside the window",
                        old, desired, attackBase, tostring(Settings.NormalDamage)))
                end
            end
        end
    else
        -- 1.7: NormalDamage at or above the base Attack: the game's own Attack, also right after a window.
        GiveBack(pawn, "Attack")
    end
    if Settings.EnemyOneShot then
        for _, damageType in ipairs(HEALTH_TYPES) do
            local name = "TakenVulnerabilityMultiplier_" .. damageType
            local _, base = AttributeValues(pawn, name)
            if base ~= nil then
                local old = WriteAttribute(pawn, name, math.max(base, 0.001) * ONE_SHOT_FACTOR)
                if old ~= nil and normalRewrites <= MAX_REWRITE_LOGS then
                    LogHit(string.format("%s %.4g -> %.4g: enemy hits kill", name, old,
                        math.max(base, 0.001) * ONE_SHOT_FACTOR))
                end
            end
        end
    else
        -- 1.7: switched off while the game runs: the damage taken back to the game's.
        for _, damageType in ipairs(HEALTH_TYPES) do
            GiveBack(pawn, "TakenVulnerabilityMultiplier_" .. damageType)
        end
    end
end

-- A trigger opens the window (or extends it) and writes the kill Attack at once.
local function OpenWindow()
    local pawn = ControlledPawn()
    if pawn == nil then
        return
    end
    if Now() >= windowUntil and redUntil == 0 then
        windowRewrites = 0
    end
    windowUntil = Now() + Settings.WindowMs / 1000
    windowWasOpen = true
    local old = WriteAttribute(pawn, "Attack", KILL_ATTACK)
    LogHit(string.format("window open for %d ms: Attack %s -> %d", Settings.WindowMs,
        old ~= nil and string.format("%.4g", old) or "(already)", KILL_ATTACK))
end

-- The last trigger: its time (Now()) and what it was.
local lastTrigger = nil
local lastTriggerKind = ""

local function OnTrigger(kind)
    if not Settings.Enable then
        return -- 1.7: switched off
    end
    local now = Now()
    if lastTrigger ~= nil and now - lastTrigger < 0.05 and lastTriggerKind == kind then
        return
    end
    lastTrigger = now
    lastTriggerKind = kind
    LogHit("TRIGGER " .. kind)
    OpenWindow()
end

-- "123 ms after the last trigger (dodge ...): in the window" or "no trigger yet".
local function WindowText()
    if lastTrigger == nil then
        return "no trigger yet"
    end
    local ms = (Now() - lastTrigger) * 1000
    local inside = Now() < windowUntil or redUntil > 0
    return string.format("%.0f ms after the last trigger (%s): %s", ms, lastTriggerKind,
        inside and "IN the window" or "outside the window")
end

-- The health watch (1.1): OnDamage did not fire in the test of 1.0, so the mod reads the health of the player (always)
-- and of the enemy of the last trigger (for WATCH_SECONDS) every WATCH_MS and logs each change.
local function ReadHealth(character)
    local ok, value = pcall(function()
        return character.AttributeSetBase.Health.CurrentValue
    end)
    return ok and value or nil
end

local watched = {}

local function Watch(character, label, seconds)
    if not Valid(character) then
        return
    end
    local key = character:GetAddress()
    local entry = watched[key] or { object = character, label = label, last = ReadHealth(character) }
    entry.untilTime = seconds and (Now() + seconds) or nil
    watched[key] = entry
end

local function CheckHealth()
    local pawn = ControlledPawn()
    if pawn ~= nil and watched[pawn:GetAddress()] == nil then
        Watch(pawn, "PLAYER", nil)
    end
    for key, entry in pairs(watched) do
        if not Valid(entry.object) or (entry.untilTime ~= nil and Now() > entry.untilTime) then
            watched[key] = nil
        else
            local health = ReadHealth(entry.object)
            if health ~= nil and entry.last ~= nil and math.abs(health - entry.last) > 0.001 then
                LogHit(string.format("health %s %s: %.1f -> %.1f (%+.1f); %s", entry.label,
                    ClassName(entry.object), entry.last, health, health - entry.last, WindowText()))
            end
            entry.last = health
        end
    end
end

-- The damage attributes of a character, once per class, to plan the damage change (way A).
local ATTRIBUTES = {
    "Attack", "Amplification_Physical", "DealtVulnerabilityMultiplier_Physical", "DealtReductionMultiplier_Physical",
    "Resistance_Physical", "TakenAdditiveMultiplier_Physical", "TakenVulnerabilityMultiplier_Physical",
    "TakenReductionMultiplier_Physical", "Amplification_PhysicalSharp", "DealtVulnerabilityMultiplier_PhysicalSharp",
    "TakenVulnerabilityMultiplier_PhysicalSharp", "Amplification_PhysicalBlunt", "Health", "Health_Max", "Shield",
    "Shachi", "Shachi_Max",
}
local dumped = {}

local function DumpAttributes(character, label)
    local class = ClassName(character)
    if not Valid(character) or dumped[class] then
        return
    end
    dumped[class] = true
    local parts = {}
    for _, name in ipairs(ATTRIBUTES) do
        local ok, text = pcall(function()
            local data = character.AttributeSetBase[name]
            if math.abs(data.CurrentValue - data.BaseValue) > 0.0001 then
                return string.format("%s %.4g (base %.4g)", name, data.CurrentValue, data.BaseValue)
            end
            return string.format("%s %.4g", name, data.CurrentValue)
        end)
        parts[#parts + 1] = ok and text or (name .. " ?")
    end
    LogHit("attributes " .. label .. " " .. class .. ": " .. table.concat(parts, ", "))
end

-- The enemy of a trigger: watch its health and log its attributes once.
local function OnTriggerSource(enemy)
    if Valid(enemy) then
        Watch(enemy, "enemy", WATCH_SECONDS)
        DumpAttributes(enemy, "enemy")
    end
    local pawn = ControlledPawn()
    if pawn ~= nil then
        DumpAttributes(pawn, "PLAYER")
    end
end

-- The gameplay events that Blueprints and scripts send through SendGameplayEventToActor; only hit, damage and death
-- events, at most MAX_EVENT_LOGS lines.
local eventLogs = 0

local function OnGameplayEventSent(actor, tag)
    local lower = tag:lower()
    if not (lower:find("hit", 1, true) or lower:find("damage", 1, true) or lower:find("die", 1, true)
            or lower:find("dead", 1, true)) then
        return
    end
    eventLogs = eventLogs + 1
    if eventLogs <= MAX_EVENT_LOGS then
        LogHit(string.format("event %s to %s %s; %s", tag, IsPlayer(actor) and "PLAYER" or "actor", ClassName(actor),
            WindowText()))
    end
end

local HOOK_GROUPS = {
    {
        label = "dodge",
        path = DODGE_CLASS,
        hooks = {
            {
                name = EVADE_EVENT_FUNCTION,
                callback = function(context, payload)
                    local ok, tag = pcall(function()
                        return payload:get().EventTag.TagName:ToString()
                    end)
                    tag = ok and tag or "?"
                    if tag:sub(1, #EVADE_EVENT_TAG) == EVADE_EVENT_TAG then
                        OnTrigger("dodge (" .. ClassName(Get(context)) .. ")")
                    end
                end,
            },
            {
                name = "OnEvadeDamage",
                callback = function(context, sourceAvatar)
                    OnTrigger("dodge (" .. ClassName(Get(context)) .. ")")
                    OnTriggerSource(Get(sourceAvatar))
                end,
            },
        },
    },
    {
        label = "red-light perfect dodge",
        path = PERFECT_DODGE_CLASS,
        hooks = {
            {
                name = "K2_ActivateAbility",
                callback = function(context)
                    local ability = Get(context)
                    OnTrigger("red-light perfect dodge (" .. ClassName(ability) .. ")")
                    -- The window stays open until the ability ends (its counter attack comes late).
                    if Settings.Enable then -- 1.7: switched off: no window
                        redUntil = Now() + RED_MAX_SECONDS
                    end
                    -- The attacker: the ability's "Current Frame" (FDeflectResultData) or its "Target".
                    local ok, enemy = pcall(function()
                        return ability["Current Frame"].SourceAvatar
                    end)
                    if not (ok and Valid(enemy)) then
                        ok, enemy = pcall(function()
                            return ability.Target
                        end)
                    end
                    OnTriggerSource(ok and enemy or nil)
                end,
            },
            {
                name = "K2_OnEndAbility",
                callback = function(context)
                    if redUntil > 0 then
                        redUntil = 0
                        windowUntil = math.max(windowUntil, Now() + Settings.WindowMs / 1000)
                        LogHit(string.format("red-light perfect dodge ended (%s): the window stays open %d ms more",
                            ClassName(Get(context)), Settings.WindowMs))
                    end
                end,
            },
        },
    },
    {
        label = "parry",
        path = PARRY_CLASS,
        hooks = {
            {
                name = "On Impact",
                callback = function(context, handle, resultData)
                    local ok, result = pcall(function()
                        return resultData:get().DeflectResult.TagName:ToString()
                    end)
                    result = ok and result or "?"
                    local found, enemy = pcall(function()
                        return resultData:get().SourceAvatar
                    end)
                    if PARRY_RESULTS[result] then
                        OnTrigger("parry " .. result .. " (" .. ClassName(Get(context)) .. ")")
                    else
                        LogHit("parry " .. result .. " (" .. ClassName(Get(context)) .. "): no trigger")
                    end
                    OnTriggerSource(found and enemy or nil)
                end,
            },
        },
    },
    {
        label = "hits taken",
        path = CHARACTER_CLASS,
        hooks = {
            {
                -- Every character; the hook runs after the game's code, so the health is the one after the hit.
                name = "OnDamage",
                callback = function(context, damageAmount, damageTags)
                    local character = Get(context)
                    local who = IsPlayer(character) and "PLAYER" or "enemy"
                    LogHit(string.format("OnDamage %s %s: damage %s, %s, tags [%s]; %s", who, ClassName(character),
                        tostring(Get(damageAmount)), HealthText(character), TagsText(damageTags), WindowText()))
                end,
            },
        },
    },
    {
        label = "damage received task",
        path = RECEIVE_DAMAGE_TASK_CLASS,
        hooks = {
            {
                name = "OnDamageReceived",
                callback = function(context, sourceASC, unmitigated, mitigated)
                    LogHit(string.format("OnDamageReceived (%s): unmitigated %s, mitigated %s",
                        ClassName(Get(context)), tostring(Get(unmitigated)), tostring(Get(mitigated))))
                end,
            },
        },
    },
    {
        label = "damage modification",
        path = DAMAGE_MODIFICATION_CLASS,
        hooks = {
            {
                name = "OnDamagePreTakeEventReceived",
                callback = function(context, payload)
                    local ok, target = pcall(function()
                        return payload:get().Target
                    end)
                    LogHit(string.format("damage pre-take event (%s) for %s", ClassName(Get(context)),
                        ok and ClassName(target) or "?"))
                end,
            },
        },
    },
    {
        label = "sent gameplay events",
        path = ABILITY_LIBRARY_CLASS,
        hooks = {
            {
                -- A static function: Blueprints and the game's scripts send events through it (C++ code does not).
                name = "SendGameplayEventToActor",
                callback = function(context, actor, eventTag)
                    local ok, tag = pcall(function()
                        return eventTag:get().TagName:ToString()
                    end)
                    if ok then
                        OnGameplayEventSent(Get(actor), tag)
                    end
                end,
            },
        },
    },
}

-- Sets the hooks of every class that is loaded now; a class that was unloaded gets them again when it is back.
local function TryHooks()
    for _, group in ipairs(HOOK_GROUPS) do
        if group.class ~= nil and not Valid(group.class) then
            group.class = nil
            Log("The " .. group.label .. " class was unloaded; its hooks are set again when it is back.")
        end
        if group.class == nil then
            local class = StaticFindObject(group.path)
            if Valid(class) then
                group.class = class
                local names = {}
                for _, hook in ipairs(group.hooks) do
                    local ok, err = pcall(RegisterHook, group.path .. ":" .. hook.name, function(context, ...)
                        local done, problem = pcall(hook.callback, context, ...)
                        if not done then
                            LogError("Error in " .. hook.name .. ": " .. tostring(problem))
                        end
                    end)
                    if ok then
                        names[#names + 1] = hook.name
                    else
                        LogError("Hook " .. hook.name .. " not set: " .. tostring(err))
                    end
                end
                Log("Hooked (" .. group.label .. "): " .. table.concat(names, ", "))
            end
        end
    end
end

RegisterLoadMapPostHook(function()
    local ok, err = pcall(function()
        lastTrigger = nil
        controller = nil
        watched = {}
        windowUntil = 0
        redUntil = 0
        TryHooks()
    end)
    if not ok then
        LogError("Error after the map load: " .. tostring(err))
    end
end)

local started, problem = pcall(TryHooks)
if not started then
    LogError("Error at start: " .. tostring(problem))
end

local function CheckStep()
    local ok, err = pcall(TryHooks)
    if not ok then
        LogError("Error: " .. tostring(err))
    end
end

-- The fast step: the attribute values (always, while Enable) and the health watch (LogHits).
local function WatchStep()
    local ok, err = pcall(KeepAttributes)
    if not ok then
        LogError("Error in the damage change: " .. tostring(err))
    end
    if Settings.Enable and Settings.LogHits then
        ok, err = pcall(CheckHealth)
        if not ok then
            LogError("Error in the health watch: " .. tostring(err))
        end
    end
end

local function ConfigStep()
    local ok, err = pcall(ReadConfig)
    if not ok then
        LogError("Error while reading config.lua: " .. tostring(err))
    end
end

-- 1.7: every loop runs on the game thread (UE4SS's Delayed Action API): no Lua on a second thread beside the hooks
-- (Witch Time's crash lesson). A UE4SS without it gets the old LoopAsync loops, and the log says so.
if type(LoopInGameThreadWithDelay) == "function" then
    LoopInGameThreadWithDelay(CHECK_INTERVAL_MS, CheckStep)
    LoopInGameThreadWithDelay(WATCH_MS, WatchStep)
    LoopInGameThreadWithDelay(CONFIG_INTERVAL_MS, ConfigStep)
else
    Log("This UE4SS has no game-thread loops (LoopInGameThreadWithDelay): the older LoopAsync is used; a newer UE4SS "
        .. "is safer.")
    local loops = { { CHECK_INTERVAL_MS, CheckStep }, { WATCH_MS, WatchStep }, { CONFIG_INTERVAL_MS, ConfigStep } }
    for _, loop in ipairs(loops) do
        local step = loop[2]
        LoopAsync(loop[1], function()
            ExecuteInGameThread(step)
            -- false keeps the loop running.
            return false
        end)
    end
end
