-- Settings of Heaven or Hell. Change a value, save the file, and start the game again: UE4SS reads it at game start.
-- A setting that this file does not have keeps its default, so an older copy of the file still works after an update.
return {
    Enable = true,              -- false: the mod does nothing
    WindowMs = 1200,            -- after a timed parry or a dodge, your hits kill for this many ms (from 50 to 5000)
    NormalDamage = 1,           -- every other hit of yours deals about this much (light hits less, heavy hits more)
    EnemyOneShot = true,        -- true: enemy hits kill you in one hit
    LogHits = false,            -- true: ue4ss\UE4SS.log names each trigger and attribute and health change (tests)
}
