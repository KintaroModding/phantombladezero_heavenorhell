-- Settings of Heaven or Hell. Change a value and save the file: the mod reads it again every 5 seconds, so the change
-- shows in the game without a restart. A file it cannot read (for example while it is saved) keeps the last settings.
-- A setting that this file does not have keeps its default, so an older copy of the file still works after an update.
return {
    Enable = true,              -- false: the mod does nothing, and your values are the game's again at once
    WindowMs = 1200,            -- after a timed parry or a dodge, your hits kill for this many ms (from 50 to 5000)
    NormalDamage = 1,           -- every other hit of yours deals about this much (light hits less, heavy hits more)
    EnemyOneShot = true,        -- true: enemy hits kill you in one hit
    LogHits = false,            -- true: ue4ss\UE4SS.log names each trigger and attribute and health change (tests)
}
