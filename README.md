# Heaven or Hell

Your hits kill only right after a timed parry or a dodge through an attack; every other hit does 1 damage, and enemies kill you in one hit.

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for Phantom Blade Zero (Unreal Engine 5.7), made with
game version `CL-301524_JKS-17219` and UE4SS `v3.0.1-1183-gcdbc0b66`; 1.7 for game version `CL-302256_JKS-17280`
(Steam build 26367565) and UE4SS `v4.0.0`. This README is for developers; what the mod does and
how to install it are in [openmods.md](openmods.md), the mod page on [openmods](https://openmods.nexus).

## How it works

- **Damage (since 1.3):** no hook sees a single hit (tests of 1.0 and 1.1: `APBZCharacter:OnDamage` and the others below
  never fired; the game calls them from C++). So the script writes the player's attribute values directly into
  `AttributeSetBase` (`CurrentValue` only; `BaseValue` stays, so the game's own recalculation brings the real values
  back when the mod stops), every 50 ms when they differ:
  - outside the window `Attack` = `NormalDamage` (when it is below the base `Attack`): a hit then deals about
    `NormalDamage` times the move's own factor (0.2 to 2.25 measured); Sha-Chi damage uses `ShachiAttack` and stays
    the game's;
  - on a trigger `Attack` = 10000000 for `WindowMs` of real time (a new trigger extends the window); the game fixes
    a hit's damage when the swing starts (test of 1.3), so a swing started in the window kills; the red-light
    perfect dodge keeps the window open while the game's perfect-dodge ability runs (`K2_ActivateAbility` to
    `K2_OnEndAbility` of `BP_PlayerPerfectDodge_Base_C`) and `WindowMs` after it, because its counter attack hit
    1.6 to 1.7 s after the trigger (at most 6 s when the end never comes);
  - `EnemyOneShot`: the player's `TakenVulnerabilityMultiplier_<type>` = base x 1000 for the health damage types
    (Physical, PhysicalSharp, PhysicalBlunt, Elemental, Fire, Toxin, Ice, Aqua, Lightning, Blood, Chaos; not the
    Sha-Chi, Poise and break types).

  1.2 used the game's helper `AttributeUtils.AddAttributeBuff` with an `FGameplayAttribute` borrowed from the game's
  damage calculator: the game crashed in its own code at the first call (an access violation reading `0x10`): the
  struct reached the game without its field path. So the script calls no game function that takes an
  `FGameplayAttribute`.

- **Triggers** (the hooks of `phantombladezero_witchtime`): the dodge ability `BP_PlayerDodge_Base_C` (the handler of
  its `GameplayEvent.Actor.HitDodge.Target` event and `OnEvadeDamage`), the red-light perfect dodge
  `BP_PlayerPerfectDodge_Base_C` (`K2_ActivateAbility`) and the parry ability `BP_StanceAction_Base_Player_C`
  (`On Impact` with `Deflect.Result.Perfect` or `.PerfectCounter`; `.Normal` is a block and does not count).
- **Hits:** `APBZCharacter:OnDamage(DamageAmount, DamageTags, EffectContext)` for every character, with the target's
  `AttributeSetBase.Health` / `Health_Max`; `UAT_WaitReceiveDamage:OnDamageReceived`;
  `UGA_DamageModificationBase:OnDamagePreTakeEventReceived` (the game's damage modification step).
- **Log (`LogHits`, off by default):** each trigger, each hit with its damage, health, tags and the time since the
  last trigger ("IN the window" or "outside the window", the real window including the red-light one).
- **1.1, because no damage hook fired in the test of 1.0:** a health watch every 50 ms (the player always, the enemy
  of the last trigger for 3 s: `SourceAvatar` of `OnEvadeDamage` and of the parry's result, the red-light ability's
  `Current Frame` or `Target`) that logs each change; the damage attributes of both, once per class; and the hit,
  damage and death events sent through `AbilitySystemBlueprintLibrary:SendGameplayEventToActor` (Blueprints and the
  game's scripts; C++ does not go through it).
- **1.7:** every loop runs on the game thread (`LoopInGameThreadWithDelay`: the hook check every 2 s, the attributes
  every 50 ms, `config.lua` every 5 s; the older `LoopAsync` ran its callback on a second thread beside the hooks,
  the pattern of Witch Time 1.7's crash; it stays only as a fallback for a UE4SS without the game-thread loops).
  `config.lua` is read live; a broken file keeps the last settings. The script remembers, per attribute it writes,
  the game's own value (taken again whenever the game recalculated it) and writes it back when a setting turns
  that part off (`Enable`, `EnemyOneShot`, or `NormalDamage` at or above the base `Attack`, also right after a
  window; 1.6 left the kill `Attack` there until the game recalculated it), while the value is still the mod's.
- **Classes:** the script looks for the classes at start, after each map load and every 2 seconds while one is
  missing, and sets the hooks once a class is there (again after it was unloaded).

## Deploy and test

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1     # copy the mod folder into the game's ue4ss\Mods
python tests\test_main.py                                 # offline test of main.lua (needs lupa)
```

`deploy.ps1` copies `src\phantombladezero_heavenorhell\` to `<game folder>\platform\steam\ue4ss\Mods\phantombladezero_heavenorhell\`. The game
folder is `$env:UE5_GAMES_DIR\PBZ`; `-GameDir` or `-ModsDir` override it. The mod folder holds
`enabled.txt`, so UE4SS starts it without an entry in `mods.txt`. An existing `Scripts\config.lua` in the game stays
(the tester's settings); `-ResetConfig` copies the shipped one. UE4SS loads Lua mods at game start. The mod writes
its lines into `ue4ss\UE4SS.log`, for example `[Heaven or Hell] 1.0 loaded.`

`tests\test_main.py` runs `main.lua` in Lua 5.4 ([lupa](https://pypi.org/project/lupa/)) with mocks of the UE4SS
functions that the script uses. It finds syntax and logic errors before a game start.

Versioning: every change raises the second number (1.0 -> 1.1) in `mod.json` and in `main.lua`:
`python scripts\bump_version.py`.

## Settings

`Scripts/config.lua` holds the player's settings, `DEFAULTS` in `main.lua` every setting with its default. Players and
mod managers keep their own `config.lua` across updates, so a new `main.lua` can meet an older file: a setting that
the file lacks, or has with another type, keeps its default, and the log says so (`ReadSettings`). Add each setting to
both files with the same value, and read it only from `Settings`, never as `config.X or default` (for a true/false
setting, `false or true` is true). `tests\test_main.py` checks that `config.lua` ships exactly the defaults, and runs
`main.lua` with a missing, empty, broken and wrong `config.lua`.

## Project layout

```
src/phantombladezero_heavenorhell/   The UE4SS mod folder: Scripts/main.lua, Scripts/config.lua, enabled.txt
tests/test_main.py    Offline test of main.lua with mocks of UE4SS and the game
docs/                 Cover and screenshots
scripts/              bump_version.py
deploy.ps1            Copies the mod folder into the game's ue4ss\Mods
mod.json              Name, version, game, engine and UE4SS version
```

## License

MIT, see [LICENSE](LICENSE).
