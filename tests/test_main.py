"""Offline test of Scripts/main.lua with lupa (Lua 5.4) and small mocks of UE4SS and the game.

The mocks stand in for the UE4SS functions that the script uses (LoopAsync, RegisterHook, RegisterLoadMapPostHook,
StaticFindObject, UEHelpers) and for the game: a clock (os.clock), the player controller and pawn, characters with an
AttributeSetBase, and the classes that the game loads later. The checks fire the hooked functions like the game does
and move the clock. The mod writes the player's attribute values (CurrentValue) directly; the checks read them and
set them back the way the game's own recalculation does.

The settings checks run main.lua with the shipped Scripts/config.lua and with the files a player may have instead:
none, an empty or older one, a broken one, one without a table, one with values of the wrong type, one with a value
out of range, one with a setting the mod does not know, and one with Enable = false. main.lua must start without an
error in each case, and a setting that the file does not give must keep its default. The shipped config.lua must hold
exactly the defaults of main.lua.

Usage:
    python tests/test_main.py        (needs lupa: python -m pip install lupa)

Exit code: 0 = all checks passed, 1 = a check failed.
"""

import json
import sys
import tempfile
from pathlib import Path

from lupa import lua54

ROOT = Path(__file__).resolve().parent.parent
MAIN = ROOT / "src" / "phantombladezero_heavenorhell" / "Scripts" / "main.lua"
CONFIG = MAIN.parent / "config.lua"

DODGE = "/PBZDeflectSystem/Abilities/BP_PlayerDodge_Base.BP_PlayerDodge_Base_C"
RED = "/PBZDeflectSystem/Abilities/BP_PlayerPerfectDodge_Base.BP_PlayerPerfectDodge_Base_C"
PARRY = "/PBZDeflectSystem/Abilities/BP_StanceAction_Base_Player.BP_StanceAction_Base_Player_C"
CHARACTER = "/Script/ProjectPBZ.PBZCharacter"
TASK = "/Script/ProjectPBZ.AT_WaitReceiveDamage"
MODIFICATION = "/Script/PBZCombatAsset.GA_DamageModificationBase"
EVADE_EVENT = DODGE + ":EventReceived_DE0795E84ADED85523B251A711345C31"
EVADE = DODGE + ":OnEvadeDamage"
RED_TRIGGER = RED + ":K2_ActivateAbility"
RED_END = RED + ":K2_OnEndAbility"
PARRY_IMPACT = PARRY + ":On Impact"
ON_DAMAGE = CHARACTER + ":OnDamage"
LIBRARY = "/Script/GameplayAbilities.AbilitySystemBlueprintLibrary"
SEND = LIBRARY + ":SendGameplayEventToActor"
ALL_HOOKS = sorted([EVADE_EVENT, EVADE, RED_TRIGGER, RED_END, PARRY_IMPACT, ON_DAMAGE, TASK + ":OnDamageReceived",
                    MODIFICATION + ":OnDamagePreTakeEventReceived", SEND])
ALL_CLASSES = "{" + ", ".join(f"'{path}'" for path in [DODGE, RED, PARRY, CHARACTER, TASK, MODIFICATION, LIBRARY]) + "}"
TIMERS = 2

MOCKS = r"""
LOG = {}
print = function(...) LOG[#LOG + 1] = table.concat({...}, "") end

-- Real time: the test moves it.
CLOCK = 0
os.clock = function() return CLOCK end

local FNameMeta = { __index = { ToString = function(self) return self.text end } }
function FName(text) return setmetatable({ text = text }, FNameMeta) end

-- A game object: valid until the test says otherwise; GetAddress is unique per object.
local ObjectMeta = { __index = {
    IsValid = function(self) return self.valid end,
    GetAddress = function(self) return tostring(self) end,
} }
function OBJECT(fields)
    fields = fields or {}
    if fields.valid == nil then fields.valid = true end
    return setmetatable(fields, ObjectMeta)
end

-- A character with an AttributeSetBase and a class name.
function CHARACTER(className, health, maxHealth)
    local object = OBJECT({ AttributeSetBase = {
        Health = { CurrentValue = health, BaseValue = health },
        Health_Max = { CurrentValue = maxHealth, BaseValue = maxHealth },
        Attack = { CurrentValue = 50, BaseValue = 40 },
        TakenVulnerabilityMultiplier_Physical = { CurrentValue = 1, BaseValue = 1 },
        TakenVulnerabilityMultiplier_PhysicalSharp = { CurrentValue = 1, BaseValue = 1 },
    } })
    object.GetClass = function() return { GetFName = function() return FName(className) end } end
    return object
end

PAWN = CHARACTER("BP_Renewal_Hun_Young_C", 850, 850)
PAWN.AttributeSetBase.Attack = { CurrentValue = 100, BaseValue = 100 }
PAWN.AttributeSetBase.TakenVulnerabilityMultiplier_ImpactShachi = { CurrentValue = 1, BaseValue = 1 }
PAWN.AttributeSetBase.TakenVulnerabilityMultiplier_Poise = { CurrentValue = 1, BaseValue = 1 }
ENEMY = CHARACTER("BP_Enemy_Bandit_C", 300, 300)
CONTROLLER = OBJECT({ Pawn = PAWN })

-- The classes that the game has loaded (path -> class object); the test fills it.
CLASSES = {}
function StaticFindObject(path)
    return CLASSES[path] or OBJECT({ valid = false })
end
function FindFirstOf(name) return nil end
function FindAllOf(name) return nil end

HOOKS = {}
function RegisterHook(path, callback)
    HOOKS[path] = callback
    return 1, 2
end
MAP_HOOKS = {}
function RegisterLoadMapPostHook(callback) MAP_HOOKS[#MAP_HOOKS + 1] = callback end

LOOPS = {}
function LoopAsync(ms, callback) LOOPS[#LOOPS + 1] = callback end
function ExecuteInGameThread(callback) callback() end

local function Invalid() return OBJECT({ valid = false }) end
package.preload["UEHelpers"] = function()
    return { GetPlayerController = function() return CONTROLLER end, GetPlayer = Invalid, GetWorld = Invalid }
end

-- Calls a hooked function like the game does, on the object; the parameters come as RemoteUnrealParam (:get()).
local function Param(value) return { get = function() return value end } end
function CALL_ON(path, object, ...)
    local params = {}
    for i, value in ipairs({...}) do params[i] = Param(value) end
    HOOKS[path](Param(object), table.unpack(params))
end
function CALL(path, className, ...)
    CALL_ON(path, CHARACTER(className, 0, 0), ...)
end
function EVENT(tag) return { EventTag = { TagName = FName(tag) } } end
function RESULT(tag) return { DeflectResult = { TagName = FName(tag) } } end
-- A FGameplayTagContainer with its TArray of tags.
function TAGS(...)
    local items = {...}
    return { GameplayTags = { ForEach = function(self, fn)
        for i, tag in ipairs(items) do fn(i, Param({ TagName = FName(tag) })) end
    end } }
end

-- Runs every timer once, as UE4SS does after their intervals.
function TICK() for i = 1, #LOOPS do LOOPS[i]() end end

function LOAD_CLASSES(paths) for _, path in ipairs(paths) do CLASSES[path] = OBJECT() end end

function HOOK_NAMES()
    local names = {}
    for path in pairs(HOOKS) do names[#names + 1] = path end
    table.sort(names)
    return table.concat(names, "\n")
end

-- The settings line of main.lua for any table: every name=value, sorted by name.
function DESCRIBE(t)
    local names = {}
    for name in pairs(t) do names[#names + 1] = tostring(name) end
    table.sort(names)
    local parts = {}
    for i, name in ipairs(names) do parts[i] = name .. "=" .. tostring(t[name]) end
    return table.concat(parts, ", ")
end
"""

# The files a player may have instead of the shipped config.lua: (case, content or None for no file, a text that
# main.lua must log). "wrong types" is made from the shipped file: every value gets another type.
PLAYER_CONFIGS = [
    ("no config.lua", None, "No config.lua"),
    ("an empty or older config.lua", "return {}\n", None),
    ("a broken config.lua", "return {\n    Enable =\n", "config.lua not read"),
    ("a config.lua without a table", "-- nothing here\n", "does not return a table"),
    ("a config.lua with wrong types", "wrong types", "must be a"),
    ("a config.lua with a value out of range", "return { WindowMs = 10 }\n", "WindowMs must be from"),
    ("a config.lua with an unknown setting", "return { NoSuchSetting = 1 }\n", "unknown setting NoSuchSetting"),
]


def lua_path(path: Path) -> str:
    return "[[" + path.as_posix() + "]]"


def run(config_folder: Path):
    """Runs main.lua with require("config") reading config.lua in config_folder, and its timer three times. A Lua
    error that stops main.lua becomes an "Error" line in the log, so the checks fail instead of the test."""
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCKS)
    lua.execute(f'package.path = {lua_path(config_folder)} .. "/?.lua"; package.cpath = ""')
    g = lua.globals()
    try:
        lua.execute(MAIN.read_text(encoding="utf-8"))
        for _ in range(3):
            lua.execute("TICK()")
    except lua54.LuaError as error:
        g.LOG[len(g.LOG) + 1] = "Error: main.lua stopped: " + str(error).splitlines()[0]
    return lua, g, [g.LOG[i].rstrip() for i in range(1, len(g.LOG) + 1)]


def settings_line(log):
    lines = [line.split("] Settings: ", 1)[1] for line in log if "] Settings: " in line]
    return lines[0] if len(lines) == 1 else None


def new_lines(g, start):
    """The log lines written since the line count start."""
    return [g.LOG[i].rstrip() for i in range(start + 1, len(g.LOG) + 1)]


def main() -> None:
    version = json.loads((ROOT / "mod.json").read_text(encoding="utf-8"))["version"]
    failures = []

    def check(condition, text):
        print(("ok    " if condition else "FAIL  ") + text)
        if not condition:
            failures.append(text)

    # The mod as players get it, with the shipped config.lua.
    lua, g, log = run(CONFIG.parent)
    for line in log:
        print("      log: " + line)
    check(len(g.LOOPS) == TIMERS, f"{TIMERS} LoopAsync timers (with LogHits: the health watch)")
    check(len(g.MAP_HOOKS) == 1, "one map load hook")
    check(any(f"{version} loaded." in line for line in log), f"load line with the version {version} of mod.json")
    check(not any("Error" in line for line in log), "no error line after three timer runs")
    check(not any("config.lua" in line for line in log), "the shipped config.lua is read without a warning")
    shipped = lua.eval(f"DESCRIBE(dofile({lua_path(CONFIG)}))")
    check(settings_line(log) == shipped, "the settings line shows the values of the shipped config.lua")

    with tempfile.TemporaryDirectory() as temp:
        folders = {}
        extra = [("Enable = false", "return { Enable = false }\n", None),
                 ("LogHits on", "return { LogHits = true }\n", None),
                 ("LogHits off", "return { LogHits = false }\n", None),
                 ("EnemyOneShot off", "return { EnemyOneShot = false }\n", None),
                 ("NormalDamage high", "return { NormalDamage = 100 }\n", None)]
        for case, content, _ in PLAYER_CONFIGS + extra:
            folder = Path(temp) / str(len(folders))
            folder.mkdir()
            if content == "wrong types":
                content = lua.eval(f"""(function()
                    local lines = {{}}
                    for name, value in pairs(dofile({lua_path(CONFIG)})) do
                        lines[#lines + 1] = string.format("    [%q] = %s,", name, type(value) == "string" and "0" or '"wrong"')
                    end
                    return "return {{\\n" .. table.concat(lines, "\\n") .. "\\n}}\\n"
                end)()""")
            if content is not None:
                (folder / "config.lua").write_text(content, encoding="utf-8")
            folders[case] = folder

        # The defaults of main.lua: the settings line with an empty config.lua.
        defaults = settings_line(run(folders["an empty or older config.lua"])[2])
        check(defaults == shipped, f"config.lua ships exactly the defaults of main.lua ({defaults})")

        for case, _, expected in PLAYER_CONFIGS:
            _, g2, log2 = run(folders[case])
            fine = (len(g2.LOOPS) == TIMERS and settings_line(log2) == defaults
                    and not any("Error" in line for line in log2))
            if expected is None:
                fine = fine and not any("config.lua" in line for line in log2)
            else:
                fine = fine and any(expected in line for line in log2)
            if case == "a config.lua with wrong types":
                count = len(list(lua.eval(f"dofile({lua_path(CONFIG)})").keys()))
                fine = fine and sum("must be a " in line for line in log2) == count
            check(fine, f"{case}: starts, every setting at its default"
                  + (f", logs '{expected}'" if expected else ", no warning"))
            if not fine:
                for line in log2:
                    print("      log: " + line)

        _, g2, log2 = run(folders["Enable = false"])
        check(len(g2.LOOPS) == 0 and len(g2.HOOKS) == 0 and "Enable=false" in (settings_line(log2) or ""),
              "Enable = false: no timer, no hook, the settings line shows Enable=false")

        # The hooks, set when their classes are loaded; the hit checks need LogHits (off in the shipped file).
        lua, g, _ = run(folders["LogHits on"])
        check(len(g.HOOKS) == 0, "no hook while the game has not loaded the classes")
        lua.execute(f"LOAD_CLASSES({ALL_CLASSES}) TICK()")
        check(lua.eval("HOOK_NAMES()") == "\n".join(ALL_HOOKS), "all nine hooks set when the classes are loaded")

        def lines_after(code):
            mark = len(g.LOG)
            lua.execute(code)
            return new_lines(g, mark)

        lines = lines_after("CLOCK = 5 CALL_ON('" + ON_DAMAGE + "', ENEMY, 25, TAGS('Damage.Cause.Normal'))")
        check(any("OnDamage enemy BP_Enemy_Bandit_C: damage 25" in line and "health 300.0 / 300.0" in line
                  and "Damage.Cause.Normal" in line and "no trigger yet" in line for line in lines),
              "a hit on an enemy: class, damage, health, tags, no trigger yet")

        lines = lines_after(f"CLOCK = 10 CALL('{EVADE_EVENT}', 'GA_Hun_AdvancedDash_Tang_C', "
                            f"EVENT('GameplayEvent.Actor.HitDodge.Target.Perfect'))")
        lines += lines_after(f"CALL('{EVADE}', 'GA_Hun_AdvancedDash_Tang_C', ENEMY, 0, true)")
        check(sum("TRIGGER dodge" in line for line in lines) == 1,
              "a dodge (event and OnEvadeDamage in the same moment) is one trigger")
        lines = lines_after("CLOCK = 10.2 CALL_ON('" + ON_DAMAGE + "', ENEMY, 40, TAGS())")
        check(any("200 ms after the last trigger (dodge" in line and "IN the window" in line for line in lines),
              "a hit 200 ms after the dodge is in the window")
        lines = lines_after("CLOCK = 11.4 CALL_ON('" + ON_DAMAGE + "', ENEMY, 40, TAGS())")
        check(any("1400 ms after" in line and "outside the window" in line for line in lines),
              "a hit 1400 ms after the dodge is outside the 1200 ms window")
        lines = lines_after("CLOCK = 11 CALL_ON('" + ON_DAMAGE + "', PAWN, 90, TAGS('Damage.Cause.Normal'))")
        check(any("OnDamage PLAYER BP_Renewal_Hun_Young_C: damage 90" in line for line in lines),
              "a hit on the player is marked PLAYER")

        lines = lines_after(f"CLOCK = 20 CALL('{PARRY_IMPACT}', 'GA_Hun_Tang_Stance_C', 1, "
                            f"RESULT('Deflect.Result.Normal'))")
        check(any("parry Deflect.Result.Normal" in line and "no trigger" in line for line in lines)
              and not any("TRIGGER" in line for line in lines), "a block is logged, no trigger")
        lines = lines_after(f"CLOCK = 21 CALL('{PARRY_IMPACT}', 'GA_Hun_Tang_Stance_C', 1, "
                            f"RESULT('Deflect.Result.Perfect'))")
        check(any("TRIGGER parry Deflect.Result.Perfect" in line for line in lines), "a timed parry is a trigger")
        lines = lines_after(f"CLOCK = 22 CALL('{PARRY_IMPACT}', 'GA_Hun_Tang_Stance_C', 1, "
                            f"RESULT('Deflect.Result.PerfectCounter'))")
        check(any("TRIGGER parry Deflect.Result.PerfectCounter" in line for line in lines),
              "a PerfectCounter parry (likely the blue light) is a trigger")
        lines = lines_after(f"CLOCK = 23 CALL('{RED_TRIGGER}', 'GA_Hun_Tang_PerfectDodge_C')")
        check(any("TRIGGER red-light perfect dodge" in line for line in lines), "a red-light perfect dodge is a trigger")

        lines = lines_after("CLOCK = 24 CALL('" + TASK + ":OnDamageReceived', 'AT_WaitReceiveDamage', 0, 50, 30)")
        lines += lines_after("CALL('" + MODIFICATION + ":OnDamagePreTakeEventReceived', 'GA_Passive_C', "
                             "{ Target = ENEMY })")
        check(any("unmitigated 50, mitigated 30" in line for line in lines)
              and any("damage pre-take event (GA_Passive_C) for BP_Enemy_Bandit_C" in line for line in lines),
              "the other damage hooks log their values")

        check(g.ENEMY.AttributeSetBase.Health.CurrentValue == 300 and g.PAWN.AttributeSetBase.Health.CurrentValue == 850,
              "the mod never writes health itself (it changes attributes)")

        # The health watch (1.1): the game changes health, the mod logs it.
        lines = lines_after("CLOCK = 30 TICK() PAWN.AttributeSetBase.Health.CurrentValue = 760 TICK()")
        check(any("health PLAYER BP_Renewal_Hun_Young_C: 850.0 -> 760.0 (-90.0)" in line for line in lines),
              "the player's health is watched all the time")
        lines = lines_after(f"CLOCK = 40 CALL('{EVADE}', 'GA_Hun_AdvancedDash_Tang_C', ENEMY, 0, true) TICK() "
                            "CLOCK = 40.2 ENEMY.AttributeSetBase.Health.CurrentValue = 200 TICK()")
        check(any("health enemy BP_Enemy_Bandit_C: 300.0 -> 200.0 (-100.0)" in line and "IN the window" in line
                  for line in lines), "the enemy of a dodge is watched; its health change is logged with the window")
        lines = lines_after("CLOCK = 44 ENEMY.AttributeSetBase.Health.CurrentValue = 150 TICK()")
        check(not any("BP_Enemy_Bandit_C: 200.0" in line for line in lines), "the enemy is watched only for 3 s")
        lines = lines_after(f"CLOCK = 50 CALL('{PARRY_IMPACT}', 'GA_Hun_Tang_Stance_C', 1, "
                            "{ DeflectResult = { TagName = FName('Deflect.Result.Perfect') }, SourceAvatar = ENEMY }) "
                            "TICK() CLOCK = 50.1 ENEMY.AttributeSetBase.Health.CurrentValue = 0 TICK()")
        check(any("BP_Enemy_Bandit_C: 150.0 -> 0.0" in line for line in lines), "the enemy of a parry is watched too")
        check(sum("attributes enemy BP_Enemy_Bandit_C: Attack 50 (base 40)" in g.LOG[i] for i in range(1, len(g.LOG) + 1))
              == 1 and any("attributes PLAYER BP_Renewal_Hun_Young_C:" in g.LOG[i] for i in range(1, len(g.LOG) + 1)),
              "the damage attributes of the enemy and the player are logged once per class")
        lines = lines_after(f"CLOCK = 60 CALL_ON('{SEND}', OBJECT(), PAWN, {{ TagName = FName('GameplayEvent.Actor.Hit.Target') }})")
        lines += lines_after(f"CALL_ON('{SEND}', OBJECT(), PAWN, {{ TagName = FName('GameplayEvent.Targeting.Lock') }})")
        check(sum("event GameplayEvent.Actor.Hit.Target to PLAYER" in line for line in lines) == 1
              and not any("Targeting" in line for line in lines), "sent hit events are logged, other events are not")
        check(not any("Error" in g.LOG[i] for i in range(1, len(g.LOG) + 1)), "no error line in the whole run")

        lua.execute(f"CLASSES['{DODGE}'].valid = false HOOKS = {{}}")
        lines = lines_after("TICK()")
        check(any("The dodge class was unloaded" in line for line in lines), "an unloaded class is noticed")

        # The damage change (1.3: direct attribute writes), in a fresh run with the shipped settings.
        lua5, g5, _ = run(folders["LogHits on"])
        attributes = g5.PAWN.AttributeSetBase
        attack = lambda: attributes.Attack.CurrentValue
        taken = lambda name: attributes["TakenVulnerabilityMultiplier_" + name].CurrentValue

        # run() already ran the timers: the pawn is there from the start.
        check(abs(attack() - 1) < 1e-9 and attributes.Attack.BaseValue == 100,
              "outside the window Attack = NormalDamage (1); the base value stays 100")
        check(taken("Physical") == 1000 and taken("PhysicalSharp") == 1000,
              "EnemyOneShot: the damage taken of the health types x1000")
        check(taken("ImpactShachi") == 1 and taken("Poise") == 1, "the Sha-Chi damage taken stays the game's")
        lua5.execute(f"LOAD_CLASSES({ALL_CLASSES}) TICK()")
        lua5.execute(f"CLOCK = 10 CALL('{EVADE}', 'GA_Hun_AdvancedDash_Tang_C', ENEMY, 0, true)")
        check(attack() == 10000000, "a dodge writes the kill Attack at once")
        lua5.execute("CLOCK = 10.3 PAWN.AttributeSetBase.Attack.CurrentValue = 100 TICK()")
        check(attack() == 10000000, "in the window, a recalculation by the game is written over again")
        lua5.execute(f"CLOCK = 10.4 CALL('{PARRY_IMPACT}', 'GA_Hun_Tang_Stance_C', 1, RESULT('Deflect.Result.Perfect'))")
        lua5.execute("CLOCK = 11.5 TICK()")
        check(attack() == 10000000, "a trigger during the window extends it (1.2 s from the new trigger)")
        mark = len(g5.LOG)
        lua5.execute("CLOCK = 11.65 TICK()")
        check(abs(attack() - 1) < 1e-9 and any("window closed (Attack was written again 1 times" in g5.LOG[i]
                                                for i in range(mark + 1, len(g5.LOG) + 1)),
              "after the window Attack is NormalDamage again; the close line counts the rewrites")
        lua5.execute("PAWN.AttributeSetBase.Attack.CurrentValue = 100 "
                     "PAWN.AttributeSetBase.TakenVulnerabilityMultiplier_Physical.CurrentValue = 1 CLOCK = 20 TICK()")
        check(abs(attack() - 1) < 1e-9 and taken("Physical") == 1000,
              "values that the game set back (death, respawn, a new buff) are written again")

        # The red-light perfect dodge (1.5): open while the game's ability runs, then WindowMs more.
        lua5.execute(f"CLOCK = 22 CALL('{RED_TRIGGER}', 'GA_Hun_Tang_PerfectDodge_C') CLOCK = 25 TICK()")
        check(attack() == 10000000, "during a red-light perfect dodge the window stays open past WindowMs (3 s)")
        mark = len(g5.LOG)
        lua5.execute("CLOCK = 25.2 PAWN.AttributeSetBase.Health.CurrentValue = 700 TICK()")
        check(any("health PLAYER" in g5.LOG[i] and "3200 ms after" in g5.LOG[i] and "IN the window" in g5.LOG[i]
                  for i in range(mark + 1, len(g5.LOG) + 1)),
              "the log says IN the window during the long red-light window (1.6 fix)")
        mark = len(g5.LOG)
        lua5.execute(f"CLOCK = 25.5 CALL('{RED_END}', 'GA_Hun_Tang_PerfectDodge_C', false) CLOCK = 26.4 TICK()")
        check(attack() == 10000000 and any("red-light perfect dodge ended" in g5.LOG[i]
                                           for i in range(mark + 1, len(g5.LOG) + 1)),
              "after the ability ends the window stays open WindowMs more")
        lua5.execute("CLOCK = 26.8 TICK()")
        check(abs(attack() - 1) < 1e-9, "then it closes")
        lua5.execute(f"CLOCK = 27 CALL('{RED_END}', 'GA_Hun_Tang_PerfectDodge_C', false) CLOCK = 27.1 TICK()")
        check(abs(attack() - 1) < 1e-9, "an ability end without a running red-light dodge opens nothing")

        lua5.execute(f"CLOCK = 30 CALL('{RED_TRIGGER}', 'GA_Hun_Tang_PerfectDodge_C') MAP_HOOKS[1]() CLOCK = 30.1 TICK()")
        check(abs(attack() - 1) < 1e-9, "a map load closes the window, also a red-light one")

        mark = len(g5.LOG)
        lua5.execute(f"CLOCK = 40 CALL('{RED_TRIGGER}', 'GA_Hun_Tang_PerfectDodge_C') CLOCK = 45.9 TICK()")
        open_before = attack()
        lua5.execute("CLOCK = 46.1 TICK()")
        check(open_before == 10000000 and abs(attack() - 1) < 1e-9
              and any("no end seen within 6 s" in g5.LOG[i] for i in range(mark + 1, len(g5.LOG) + 1)),
              "when the end never comes, the red-light window closes 6 s after the start")
        check(not any("Error" in g5.LOG[i] for i in range(1, len(g5.LOG) + 1)), "no error line in the damage run")

        lua6, g6, _ = run(folders["EnemyOneShot off"])
        check(g6.PAWN.AttributeSetBase.TakenVulnerabilityMultiplier_Physical.CurrentValue == 1
              and abs(g6.PAWN.AttributeSetBase.Attack.CurrentValue - 1) < 1e-9,
              "EnemyOneShot = false: the damage taken stays the game's, Attack is still lowered")

        lua7, g7, _ = run(folders["NormalDamage high"])
        check(g7.PAWN.AttributeSetBase.Attack.CurrentValue == 100,
              "NormalDamage at or above the base Attack: Attack stays the game's outside the window")

        # LogHits off: no hit lines.
        lua4, g4, _ = run(folders["LogHits off"])
        lua4.execute(f"LOAD_CLASSES({{'{CHARACTER}'}}) TICK()")
        mark = len(g4.LOG)
        lua4.execute("CLOCK = 5 CALL_ON('" + ON_DAMAGE + "', ENEMY, 25, TAGS())")
        check(len(g4.LOG) == mark and len(g4.LOOPS) == TIMERS,
              "LogHits = false: no hit lines (the fast loop still keeps the attributes)")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
