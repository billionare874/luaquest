--[[
    All-In-One MacroQuest Lua controller.
    Provides configurable automation for every EverQuest class including buffs, DPS,
    healing, custom conditional actions, class specific specialties, cooperative monk pulling,
    complete heal chains, charm control, and a camp/AFK mode. The script exposes a UI per class
    and allows deep customization of behaviors with optional conditional expressions.

    Usage:
        /lua run main            -- load script (assuming this file is main.lua)
        /aio help                -- display help

    Main features:
        * Buff/DPS/Heal/Utility automation
        * Custom "if" rules allowing arbitrary conditions and commands
        * Per-class configuration and special features (Charm, Cannibalization, Lay Hands, CH chains, Sneak Attack, etc.)
        * Coordinated monk pulling with Phantom Shadow AA and multi-puller collaboration
        * Camp/Anchor control for AFK style play
        * Full ImGui UI to edit settings live per class
--]]

local mq = require('mq')
local ImGui = require('ImGui')

local scriptName = 'aio'
local version = '1.0.0'

local classShort = (mq.TLO.Me.Class.ShortName() or 'GEN'):upper()
local classLong = mq.TLO.Me.Class.Name() or 'Unknown'
local charName = mq.TLO.Me.CleanName() or 'Player'

local scriptState = {
    running = true,
    paused = false,
    showUI = true,
    statusText = 'Idle',
    lastAction = '',
    debug = false,
    pull = {state = 'idle', targetID = nil, startTime = 0, phantomUsed = false, usingNav = false},
    chChain = {nextCast = 0, casting = false, lastTick = 0},
    timers = {},

}

local function now()
    if mq.gettime then
        return mq.gettime()
    end
    return os.clock() * 1000
end

local function printf(level, msg, ...)
    local formatted = string.format(msg, ...)
    if mq and mq.printf then
        mq.printf('\aw[AIO]\ax [\ag%s\ax] %s', level, formatted)
    else
        print(string.format('[AIO] [%s] %s', level, formatted))
    end
end

local configDir = mq.configDir or mq.TLO.MacroQuest.Path.Config()
if type(configDir) ~= 'string' then
    configDir = mq.luaDir or '.'
end
local configFile = string.format('%s/%s_config.lua', configDir, scriptName)
local pullCoordinatorFile = string.format('%s/%s_monk_coord.lua', configDir, scriptName)
local teamStateFile = string.format('%s/%s_team.lua', configDir, scriptName)

--------------------------------------------------------------------------------
-- Serialization helpers ------------------------------------------------------
--------------------------------------------------------------------------------
local function serializeValue(value, indent)
    indent = indent or 0
    local prefix = string.rep(' ', indent)
    if type(value) == 'table' then
        local isArray = true
        local index = 1
        for k, _ in pairs(value) do
            if k ~= index then
                isArray = false
                break
            end
            index = index + 1
        end
        local parts = {'{'}
        local innerIndent = indent + 4
        if isArray then
            for i = 1, #value do
                table.insert(parts, string.format('\n%s%s,', string.rep(' ', innerIndent), serializeValue(value[i], innerIndent)))
            end
        else
            for k, v in pairs(value) do
                local key
                if type(k) == 'string' and k:match('^[_%a][_%w]*$') then
                    key = k
                else
                    key = string.format('[%s]', serializeValue(k, 0))
                end
                table.insert(parts, string.format('\n%s%s = %s,', string.rep(' ', innerIndent), key, serializeValue(v, innerIndent)))
            end
        end
        if #parts > 1 then
            table.insert(parts, string.format('\n%s}', prefix))
        else
            parts[2] = '}'
        end
        return table.concat(parts)
    elseif type(value) == 'string' then
        return string.format('%q', value)
    elseif type(value) == 'number' then
        return tostring(value)
    elseif type(value) == 'boolean' then
        return value and 'true' or 'false'
    else
        return 'nil'
    end
end

local function saveTable(filename, tbl)
    local ok, err = pcall(function()
        local file = assert(io.open(filename, 'w+'))
        file:write('return ' .. serializeValue(tbl, 0))
        file:close()
    end)
    if not ok then
        printf('ERROR', 'Failed to save %s: %s', filename, err)
    end
end

local function loadTable(filename)
    local loader = loadfile(filename)
    if not loader then return nil end
    local ok, result = pcall(loader)
    if not ok then
        printf('ERROR', 'Failed to load %s: %s', filename, result)
        return nil
    end
    return result
end

local teamState = {lastRead = 0, data = {members = {}, actions = {}, requests = {}}}

local function ensureTeamStateTables(data)
    data = data or {}
    data.members = data.members or {}
    data.actions = data.actions or {}
    data.requests = data.requests or {}
    return data
end

local function pruneTeamState(data)
    data = ensureTeamStateTables(data)
    local current = os.time()
    for name, info in pairs(data.members) do
        if current - (info.timestamp or 0) > 10 then
            data.members[name] = nil
        end
    end
    for actionType, actionList in pairs(data.actions) do
        for key, action in pairs(actionList) do
            if current >= (action.expires or 0) then
                actionList[key] = nil
            end
        end
        if not next(actionList) then
            data.actions[actionType] = nil
        end
    end
    for requestType, requests in pairs(data.requests) do
        local kept = {}
        for _, req in ipairs(requests) do
            if current < (req.expires or 0) then
                table.insert(kept, req)
            end
        end
        if #kept > 0 then
            data.requests[requestType] = kept
        else
            data.requests[requestType] = nil
        end
    end
    return data
end

local function loadTeamState(force)
    if not force and now() - (teamState.lastRead or 0) < 250 then
        return teamState.data
    end
    teamState.data = ensureTeamStateTables(loadTable(teamStateFile) or {})
    teamState.lastRead = now()
    return teamState.data
end

local function saveTeamState(data)
    teamState.data = pruneTeamState(data)
    saveTable(teamStateFile, teamState.data)
    teamState.lastRead = now()
end

local function teamActionInProgress(actionType, key)
    if not actionType or not key then return nil end
    local data = loadTeamState()
    local actions = data.actions[actionType]
    if not actions then return nil end
    local action = actions[key]
    if not action then return nil end
    if os.time() >= (action.expires or 0) then
        actions[key] = nil
        saveTeamState(data)
        return nil
    end
    return action
end

local function registerTeamAction(actionType, key, duration, info)
    if not actionType or not key then return end
    local data = loadTeamState()
    data.actions[actionType] = data.actions[actionType] or {}
    data.actions[actionType][key] = {
        by = charName,
        started = os.time(),
        expires = os.time() + math.max(duration or 2, 1),
        info = info or {},
    }
    saveTeamState(data)
end

local function clearTeamAction(actionType, key)
    if not actionType or not key then return end
    local data = loadTeamState()
    local actions = data.actions[actionType]
    if actions and actions[key] then
        actions[key] = nil
        saveTeamState(data)
    end
end

local function updateTeamStatus(profile)
    if now() - (scriptState.timers.teamStatus or 0) < 1000 then return end
    scriptState.timers.teamStatus = now()
    local data = loadTeamState()
    local target = mq.TLO.Target
    local targetID, targetName = 0, ''
    if target and target() then
        targetID = target.ID() or 0
        targetName = target.CleanName() or ''
    end
    data.members[charName] = {
        class = classShort,
        hp = mq.TLO.Me.PctHPs() or 100,
        mana = mq.TLO.Me.PctMana() or 0,
        endurance = mq.TLO.Me.PctEndurance() or 0,
        inCombat = mq.TLO.Me.CombatState() == 'COMBAT',
        status = scriptState.statusText,
        pullState = scriptState.pull.state,
        targetID = targetID,
        targetName = targetName,
        camp = profile.camp.anchor,
        timestamp = os.time(),
    }
    saveTeamState(data)
end

local function removeTeamStatus()
    local data = loadTeamState(true)
    data.members[charName] = nil
    data.actions = data.actions or {}
    for actionType, actions in pairs(data.actions) do
        for key, action in pairs(actions) do
            if action.by == charName then
                actions[key] = nil
            end
        end
        if not next(actions) then
            data.actions[actionType] = nil
        end
    end
    saveTeamState(data)
end

--------------------------------------------------------------------------------
-- Default configuration ------------------------------------------------------
--------------------------------------------------------------------------------
local function baseProfile()
    return {
        enabled = true,
        general = {
            buffs = true,
            dps = true,
            heals = true,
            utility = true,
            specials = true,
            assist = {
                enabled = true,
                mode = 'manual',
                target = '',
                xtarSlot = 1,
                stick = true,
                stickDist = 10,
                stickMode = 'behind',
                stickBreakOnTargetLoss = true,
            },
            restMana = 70,
            restEndurance = 30,
            restHP = 80,
            allowPullingWhileCamped = false,
        },
        buffs = {
            outOfCombatOnly = false,
            list = {},
        },
        dps = {
            rotation = {},
            burns = {enabled = false, trigger = 35, abilities = {}},
            chaseRange = 40,
            melee = true,
            ranged = false,
        },
        heals = {
            self = {enabled = true, threshold = 50, entry = {type = 'Spell', name = '', gem = 1}},
            group = {},
            cures = {},
            rez = {enabled = true, spell = 'Reviviscence', gem = 1, announce = '/rs >> Rez on %s <<'},
        },
        utility = {
            clickies = {},
            movement = {stick = true, chase = false, chaseTarget = '', chaseDistance = 20},
            evac = {enabled = false, spell = ''},
        },
        camp = {
            enabled = false,
            anchor = nil,
            radius = 40,
            returnToCamp = true,
            chaseLeader = '',
            leashing = true,
        },
        pull = {
            enabled = false,
            radius = 120,
            minRange = 30,
            maxActive = 2,
            navCommand = '/nav spawnid %d',
            usePhantom = true,
            phantomID = 968,
            phantomName = 'Phantom Shadow',
            feignAbility = 'Feign Death',
            feignPctHP = 35,
            feignCooldown = 12,
            tag = 'PULLER',
            sync = {enabled = true, staleSeconds = 30},
        },
        custom = {
            entries = {},
        },
        specials = {},
    }
end

local function mergeTable(base, extra)
    for k, v in pairs(extra) do
        if type(v) == 'table' then
            if type(base[k] or false) == 'table' then
                mergeTable(base[k], v)
            else
                base[k] = v
            end
        else
            base[k] = v
        end
    end
end

local function applyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == 'table' then
            if type(target[key]) ~= 'table' then
                target[key] = {}
            end
            applyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local function clericDefaults(profile)
    profile.heals.self.entry.name = 'Divine Aura'
    profile.heals.group = {
        {enabled = true, threshold = 50, entry = {type = 'Spell', name = 'Word of Greater Reformation', gem = 3}},
        {enabled = true, threshold = 70, entry = {type = 'Spell', name = 'Remedy', gem = 2}},
    }
    profile.specials.chChain = {
        enabled = false,
        spell = 'Complete Heal',
        gem = 4,
        interval = 3.0,
        order = 1,
        chainSize = 3,
        startDelay = 0,
        announce = true,
        channel = '/rs',
        message = 'CH %s (#%d/%d)',
        target = 'maintank',
    }
end

local function shamanDefaults(profile)
    profile.specials.cannibalize = {
        enabled = true,
        ability = 'Cannibalization',
        type = 'AA',
        aaID = 370,
        minHP = 60,
        manaBelow = 85,
        allowCombat = true,
        announce = false,
    }
end

local function paladinDefaults(profile)
    profile.specials.layHands = {
        enabled = true,
        threshold = 25,
        target = 'maintank',
        command = '/alt activate 2000',
        announce = '/rs Lay on Hands -> %s',
    }
end

local function rogueDefaults(profile)
    profile.specials.sneakAttack = {
        enabled = true,
        ability = 'Sneak Attack',
        cooldown = 12,
        backstab = 'Backstab',
        usePoisons = false,
    }
end

local function monkDefaults(profile)
    profile.pull.enabled = true
    profile.pull.radius = 140
    profile.pull.maxActive = 3
    profile.pull.usePhantom = true
    profile.pull.feignAbility = 'Feign Death'
    profile.pull.sync.enabled = true
end

local function bardDefaults(profile)
    profile.specials.charm = {
        enabled = false,
        spell = 'Slumber of Silisia',
        gem = 1,
        targetFilter = 'npc radius 80',
        breakHP = 25,
        rebreak = true,
        mezOnBreak = true,
        mezzSpell = '',
        mezzGem = 1,
        recharmDelay = 2.0,
        suppressSeconds = 6.0,
    }
end

local function enchanterDefaults(profile)
    profile.specials.charm = {
        enabled = false,
        spell = 'Beguile',
        gem = 1,
        targetFilter = 'npc radius 80',
        breakHP = 25,
        rebreak = true,
        mezzSpell = 'Color Conflux',
        mezzGem = 2,
        mezOnBreak = true,
        recharmDelay = 2.0,
        suppressSeconds = 6.0,
    }
end

local function necromancerDefaults(profile)
    profile.specials.charm = {
        enabled = false,
        spell = 'Charm Undead',
        gem = 1,
        targetFilter = 'npc radius 80 undead',
        breakHP = 35,
        rebreak = true,
        mezzSpell = '',
        mezzGem = 1,
        mezOnBreak = false,
        recharmDelay = 2.5,
        suppressSeconds = 6.0,
    }
end

local function druidDefaults(profile)
    profile.utility.evac = {enabled = true, spell = 'Succor: Evacuate'}
end

local classDefaultFns = {
    CLR = clericDefaults,
    SHM = shamanDefaults,
    PAL = paladinDefaults,
    ROG = rogueDefaults,
    MNK = monkDefaults,
    BRD = bardDefaults,
    ENC = enchanterDefaults,
    NEC = necromancerDefaults,
    DRU = druidDefaults,
}

local config = {
    version = 1,
    general = {
        autoSave = true,
        saveInterval = 300,
        announceChannel = '/gsay',
        allowAutomationWhileAFK = true,
    },
    classes = {},
    lastSave = now(),
}

local function ensureProfile()
    local defaults = baseProfile()
    if not config.classes[classShort] then
        config.classes[classShort] = defaults
        if classDefaultFns[classShort] then
            classDefaultFns[classShort](config.classes[classShort])
        end
    else
        applyDefaults(config.classes[classShort], defaults)
    end
    return config.classes[classShort]
end

--------------------------------------------------------------------------------
-- Utility helpers ------------------------------------------------------------
--------------------------------------------------------------------------------
local function evaluateCondition(expression, profile, envExt)
    if not expression or expression == '' then
        return true
    end
    local env = {
        mq = mq,
        Me = mq.TLO.Me,
        Target = mq.TLO.Target,
        Pet = mq.TLO.Me.Pet,
        Spawn = mq.TLO.Spawn,
        Group = mq.TLO.Group,
        Raid = mq.TLO.Raid,
        profile = profile,
        class = classShort,
        state = scriptState,
    }
    if envExt then
        for k, v in pairs(envExt) do env[k] = v end
    end
    setmetatable(env, {__index = _G})
    local chunk, err = load('return (' .. expression .. ')', 'custom_condition', 't', env)
    if not chunk then
        if scriptState.debug then
            printf('WARN', 'Condition error "%s": %s', expression, err)
        end
        return false
    end
    local ok, result = pcall(chunk)
    if not ok then
        if scriptState.debug then
            printf('WARN', 'Condition runtime error "%s": %s', expression, result)
        end
        return false
    end
    return not not result
end

local function canUse(entry)
    if entry.cooldown and entry.cooldown > 0 then
        local last = entry.lastCast or 0
        if now() - last < entry.cooldown * 1000 then
            return false
        end
    end
    if entry.type == 'Spell' then
        local ready = mq.TLO.Me.SpellReady(entry.name)
        return ready() and ready() > 0
    elseif entry.type == 'AA' then
        local aaKey = entry.id or entry.name
        local ready = mq.TLO.Me.AltAbilityReady(aaKey)
        return ready() and ready() > 0
    elseif entry.type == 'Disc' then
        local ready = mq.TLO.Me.CombatAbilityReady(entry.name)
        return ready() and ready() > 0
    elseif entry.type == 'Item' then
        local item = mq.TLO.FindItem(entry.name)
        return item() and item.TimerReady() == 0
    elseif entry.type == 'Command' then
        return true
    elseif entry.type == 'Ability' then
        local ability = mq.TLO.Me.AbilityReady(entry.name)
        return ability() and ability() > 0
    end
    return false
end

local function targetByConfig(target)
    if not target or target == '' then
        return
    end

    local lowered = target:lower()
    if lowered == 'self' or lowered == 'current' or lowered == 'target' then
        return
    end

    if lowered == 'none' or lowered == 'clear' then
        mq.cmd('/target clear')
        return
    end

    if lowered == 'maintank' then
        local mt = mq.TLO.Group.MainTank
        if mt and mt() and mt() ~= '' then
            mq.cmdf('/target %s', mt())
        end
        return
    end

    if lowered == 'mainassist' then
        local ma = mq.TLO.Group.MainAssist
        if ma and ma() and ma() ~= '' then
            mq.cmdf('/assist %s', ma())
        end
        return
    end

    local xtarSlot = target:match('^[Xx][Tt][Aa][Rr](%d+)$')
    if xtarSlot then
        local slotNum = tonumber(xtarSlot)
        if slotNum then
            mq.cmdf('/xtar %d', slotNum)
        end
        return
    end

    if target:sub(1, 5):lower() == 'name:' then
        local name = target:sub(6):gsub('^%s+', ''):gsub('%s+$', '')
        if name ~= '' then
            mq.cmdf('/target "%s"', name)
        end
        return
    end

    mq.cmdf('/target %s', target)
end

local function executeEntry(entry, profile)
    local target = entry.target or 'self'
    if target ~= 'self' and target ~= '' then
        targetByConfig(target)
        mq.delay(50)
    end
    if entry.type == 'Spell' then
        local gem = entry.gem or 1
        if target == 'self' or target == '' then
            mq.cmdf('/casting "%s" gem%d', entry.name, gem)
        else
            mq.cmdf('/casting "%s" gem%d', entry.name, gem)
        end
    elseif entry.type == 'AA' then
        local aaKey = entry.id or entry.name
        mq.cmdf('/alt activate %s', aaKey)
    elseif entry.type == 'Disc' then
        mq.cmdf('/disc %s', entry.name)
    elseif entry.type == 'Item' then
        mq.cmdf('/useitem "%s"', entry.name)
    elseif entry.type == 'Command' then
        mq.cmd(entry.command or entry.name)
    elseif entry.type == 'Ability' then
        mq.cmdf('/doability "%s"', entry.name)
    end
    entry.lastCast = now()
    scriptState.lastAction = string.format('%s (%s)', entry.name or entry.command or 'unknown', entry.type or 'Unknown')
end

local function estimateActionDuration(entry)
    if not entry then return 3 end
    if type(entry.castTime) == 'number' and entry.castTime > 0 then
        return entry.castTime
    end
    if type(entry.duration) == 'number' and entry.duration > 0 then
        return entry.duration
    end
    if entry.type == 'Spell' then
        return 3
    elseif entry.type == 'Item' then
        return 4
    elseif entry.type == 'Command' then
        return 1
    else
        return 2
    end
end

local function processEntry(entry, profile, envExt, context)
    if entry.enabled ~= nil and not entry.enabled then
        return false
    end
    if not entry.name and entry.type ~= 'Command' then
        return false
    end
    if not canUse(entry) then
        return false
    end
    if not evaluateCondition(entry.condition, profile, envExt) then
        return false
    end
    local share = context and context.shareAction
    local shareType, shareKey
    if share then
        shareType = share.type or share.actionType
        shareKey = share.key or share.actionKey
        if shareType and shareKey then
            if not share.allowOverlap then
                local existing = teamActionInProgress(shareType, shareKey)
                if existing and existing.by ~= charName then
                    return false
                end
            end
            if share.register ~= false then
                registerTeamAction(shareType, shareKey, share.duration or estimateActionDuration(entry), share.info)
            end
        else
            share = nil
        end
    end
    executeEntry(entry, profile)
    if share and share.clearOnExecute and shareType and shareKey then
        clearTeamAction(shareType, shareKey)
    end
    return true
end

local function iterateList(list, profile, envExt)
    if not list then return end
    for _, entry in ipairs(list) do
        processEntry(entry, profile, envExt)
    end
end

--------------------------------------------------------------------------------
-- Class special logic --------------------------------------------------------
--------------------------------------------------------------------------------
local function handleCharm(profile)
    local charm = profile.specials and profile.specials.charm
    if not charm or not charm.enabled then
        return
    end

    local state = scriptState.charm
    if not state then
        state = {}
        scriptState.charm = state
    end
    state.ignoreTargets = state.ignoreTargets or {}

    local currentTime = now()
    for id, expiry in pairs(state.ignoreTargets) do
        if expiry and currentTime >= expiry then
            state.ignoreTargets[id] = nil
        end
    end

    local function castCharmSpell()
        if not charm.spell or charm.spell == '' then return false end
        local entry = {
            type = 'Spell',
            name = charm.spell,
            gem = charm.gem or 1,
            target = 'current',
            condition = charm.condition or '',
        }
        processEntry(entry, profile, {Target = mq.TLO.Target})
        scriptState.lastAction = string.format('Charm: %s', charm.spell)
        return true
    end

    local function castMezSpell()
        if not charm.mezzSpell or charm.mezzSpell == '' then return false end
        local entry = {
            type = 'Spell',
            name = charm.mezzSpell,
            gem = charm.mezzGem or 1,
            target = 'current',
            condition = charm.mezCondition or '',
        }
        processEntry(entry, profile, {Target = mq.TLO.Target})
        scriptState.lastAction = string.format('Mez: %s', charm.mezzSpell)
        return true
    end

    local breakHP = charm.breakHP or 25
    local rebreak = charm.rebreak ~= false
    local cooldownMs = math.floor(math.max(charm.recharmDelay or 2.0, 0) * 1000)
    local suppressMs = math.floor(math.max(charm.suppressSeconds or 6.0, 0) * 1000)
    local postMezMs = 1500

    state.nextCharmAt = state.nextCharmAt or 0

    local pet = mq.TLO.Me.Pet
    local petID = pet() and pet.ID() or nil
    if petID and petID > 0 then
        state.hadPet = true
        state.lastPetID = petID
        local hp = pet.PctHPs() or 100
        state.lastPetHP = hp
        if state.pendingRecharm then
            state.pendingRecharm = false
            state.pendingMez = false
            state.pendingRecharmStart = nil
        end
        if hp and hp > 0 and hp < breakHP then
            if not state.lastBackoff or currentTime - state.lastBackoff > 750 then
                mq.cmd('/pet back off')
                state.lastBackoff = currentTime
            end
        end
        return
    end

    if state.hadPet then
        state.hadPet = false
        if state.lastPetID and rebreak and not state.ignoreTargets[state.lastPetID] then
            state.pendingRecharm = true
            state.pendingRecharmStart = currentTime
            if charm.mezOnBreak and charm.mezzSpell and charm.mezzSpell ~= '' then
                state.pendingMez = true
                state.nextMezAt = currentTime
            else
                state.pendingMez = false
            end
        else
            state.pendingRecharm = false
            state.pendingMez = false
            state.pendingRecharmStart = nil
        end
    end

    if state.pendingRecharm and state.lastPetID then
        if suppressMs > 0 and state.pendingRecharmStart and currentTime - state.pendingRecharmStart > suppressMs then
            state.ignoreTargets[state.lastPetID] = currentTime + suppressMs
            state.pendingRecharm = false
            state.pendingMez = false
            state.pendingRecharmStart = nil
        else
            local spawn = mq.TLO.Spawn(string.format('id %d', state.lastPetID))
            if not spawn() or spawn.Dead() or spawn.Type() == 'Corpse' then
                state.ignoreTargets[state.lastPetID] = currentTime + suppressMs
                state.pendingRecharm = false
                state.pendingMez = false
                state.pendingRecharmStart = nil
                state.lastPetID = nil
            else
                if mq.TLO.Target.ID() ~= state.lastPetID then
                    mq.cmdf('/target id %d', state.lastPetID)
                    mq.delay(100)
                end
                if state.pendingMez then
                    if currentTime >= (state.nextMezAt or 0) and not mq.TLO.Me.Casting() then
                        if castMezSpell() then
                            local after = now()
                            state.nextCharmAt = math.max(state.nextCharmAt or 0, after + postMezMs)
                            state.lastMezAt = after
                        end
                        state.pendingMez = false
                    end
                    return
                end
                if mq.TLO.Me.Casting() then
                    return
                end
                if currentTime < state.nextCharmAt then
                    return
                end
                if castCharmSpell() then
                    local attempt = now()
                    state.lastCharmAttempt = attempt
                    state.nextCharmAt = attempt + cooldownMs
                end
                return
            end
        end
    end

    if currentTime < state.nextCharmAt then
        return
    end

    local target = mq.TLO.Target
    local manualTarget = target() and target.Type() ~= 'Corpse'
    if manualTarget then
        if state.ignoreTargets[target.ID()] and currentTime < state.ignoreTargets[target.ID()] then
            manualTarget = false
            target = nil
        end
    else
        target = nil
    end
    if not target and charm.targetFilter and charm.targetFilter ~= '' then
        local candidate = mq.TLO.NearestSpawn(charm.targetFilter)
        if candidate() and candidate.Type() ~= 'Corpse' then
            if not state.ignoreTargets[candidate.ID()] or currentTime >= state.ignoreTargets[candidate.ID()] then
                target = candidate
            end
        end
    end
    if not target or not target() then
        return
    end
    if mq.TLO.Target.ID() ~= target.ID() then
        mq.cmdf('/target id %d', target.ID())
        mq.delay(100)
    end
    if mq.TLO.Me.Casting() then
        return
    end
    if castCharmSpell() then
        local attempt = now()
        state.lastCharmAttempt = attempt
        state.nextCharmAt = attempt + cooldownMs
        state.lastPetID = target.ID()
    end
end

local function handleCannibalize(profile)
    local cann = profile.specials and profile.specials.cannibalize
    if not cann or not cann.enabled then
        return
    end
    local mana = mq.TLO.Me.PctMana() or 100
    local hp = mq.TLO.Me.PctHPs() or 100
    if mana > (cann.manaBelow or 85) then
        return
    end
    if hp < (cann.minHP or 60) then
        return
    end
    if not cann.allowCombat and mq.TLO.Me.CombatState() == 'COMBAT' then
        return
    end
    local entry = {
        name = cann.ability,
        type = cann.type or 'AA',
        id = cann.aaID,
        condition = cann.condition,
        target = 'self',
        cooldown = cann.cooldown or 8,
    }
    processEntry(entry, profile)
    if cann.announce then
        mq.cmdf('/rs Cannibalization (%d%% mana)', mana)
    end
end

local function resolveTargetString(target)
    if not target or target == '' or target == 'self' then
        return charName
    end
    if target == 'maintank' then
        local mt = mq.TLO.Group.MainTank
        return (mt and mt() and mt() ~= '' and mt()) or charName
    elseif target == 'mainassist' then
        local ma = mq.TLO.Group.MainAssist
        return (ma and ma() and ma() ~= '' and ma()) or charName
    else
        return target
    end
end

local function handleLayHands(profile)
    local loh = profile.specials and profile.specials.layHands
    if not loh or not loh.enabled then
        return
    end
    local targetName = resolveTargetString(loh.target)
    if not targetName then return end

    local hp
    if targetName == charName then
        hp = mq.TLO.Me.PctHPs()
    else
        local spawn = mq.TLO.Spawn(string.format('pc %s', targetName))
        if spawn() then
            hp = spawn.PctHPs()
        end
    end

    if hp and hp <= (loh.threshold or 25) then
        mq.cmdf('/target %s', targetName)
        mq.delay(50)
        if loh.command and loh.command ~= '' then
            mq.cmd(loh.command)
        else
            mq.cmd('/alt activate 2000')
        end
        if loh.announce and loh.announce ~= '' then
            mq.cmdf(loh.announce, targetName)
        end
        scriptState.lastAction = 'Lay on Hands'
    end
end

local function handleSneakAttack(profile)
    local sa = profile.specials and profile.specials.sneakAttack
    if not sa or not sa.enabled then
        return
    end
    if mq.TLO.Me.Class.ShortName() ~= 'ROG' then
        return
    end
    if not mq.TLO.Target() or mq.TLO.Target.Type() == 'Corpse' then
        return
    end
    if mq.TLO.Me.CombatAbilityReady(sa.ability)() then
        mq.cmdf('/doability "%s"', sa.ability)
        scriptState.lastAction = sa.ability
    end
    if sa.backstab and mq.TLO.Me.AbilityReady(sa.backstab)() then
        mq.cmdf('/doability "%s"', sa.backstab)
        scriptState.lastAction = sa.backstab
    end
end

local function handleCharmClasses(profile)
    if classShort == 'ENC' or classShort == 'BRD' or classShort == 'NEC' then
        handleCharm(profile)
    end
end

local function handleSpecials(profile)
    if not profile.general.specials then
        return
    end
    handleCharmClasses(profile)
    if classShort == 'SHM' then
        handleCannibalize(profile)
    elseif classShort == 'PAL' then
        handleLayHands(profile)
    elseif classShort == 'ROG' then
        handleSneakAttack(profile)
    end
end

--------------------------------------------------------------------------------
-- Complete heal chain --------------------------------------------------------
--------------------------------------------------------------------------------
local chCoordinator = {lastUpdate = 0, file = string.format('%s/%s_ch_chain.lua', configDir, scriptName)}

local function loadCHCoordinator()
    if now() - (chCoordinator.lastUpdate or 0) < 1000 then
        return chCoordinator.data or {members = {}}
    end
    local data = loadTable(chCoordinator.file) or {members = {}}
    chCoordinator.data = data
    chCoordinator.lastUpdate = now()
    return data
end

local function saveCHCoordinator(data)
    chCoordinator.data = data
    chCoordinator.lastUpdate = now()
    saveTable(chCoordinator.file, data)
end

local function updateCHChain(profile)
    local chain = profile.specials and profile.specials.chChain
    if not chain or not chain.enabled then
        return
    end
    local data = loadCHCoordinator()
    data.members = data.members or {}
    data.members[charName] = {
        order = chain.order or 1,
        chainSize = chain.chainSize or 1,
        interval = chain.interval or 3.0,
        updated = os.time(),
    }
    -- cleanup stale entries
    for name, info in pairs(data.members) do
        if os.time() - (info.updated or 0) > 60 then
            data.members[name] = nil
        end
    end
    saveCHCoordinator(data)

    local state = scriptState.chChain
    local interval = (chain.interval or 3.0) * 1000
    local rotation = (chain.chainSize or 1) * interval
    if not state.nextCast or now() < state.nextCast - interval * (chain.chainSize or 1) then
        local offset = (chain.order - 1) * interval + (chain.startDelay or 0) * 1000
        state.nextCast = now() + offset
        state.casting = false
    end

    if now() >= (state.nextCast or 0) then
        local target = resolveTargetString(chain.target or 'maintank')
        if target then
            mq.cmdf('/target %s', target)
            mq.delay(30)
            local entry = {type = 'Spell', name = chain.spell, gem = chain.gem or 1, target = 'current'}
            processEntry(entry, profile, nil, {
                shareAction = {
                    type = 'heal',
                    key = string.format('CH:%s', target),
                    duration = chain.interval or estimateActionDuration(entry),
                    info = {target = target, order = chain.order, chainSize = chain.chainSize, spell = chain.spell, mode = 'ch'},
                },
            })
            if chain.announce and chain.channel then
                mq.cmdf('%s ' .. chain.message, chain.channel, target, chain.order or 1, chain.chainSize or 1)
            end
            state.nextCast = now() + rotation
        end
    end
end

--------------------------------------------------------------------------------
-- Monk pull coordination -----------------------------------------------------
--------------------------------------------------------------------------------
local pullCoordinator = {lastRead = 0, data = {monks = {}}}

local function loadPullCoordinator()
    if now() - (pullCoordinator.lastRead or 0) < 1000 then
        return pullCoordinator.data
    end
    pullCoordinator.data = loadTable(pullCoordinatorFile) or {monks = {}}
    pullCoordinator.lastRead = now()
    return pullCoordinator.data
end

local function savePullCoordinator(data)
    pullCoordinator.data = data
    pullCoordinator.lastRead = now()
    saveTable(pullCoordinatorFile, data)
end

local function updatePullStatus(status, targetID)
    local profile = ensureProfile()
    local syncSeconds = (profile.pull and profile.pull.sync and profile.pull.sync.staleSeconds) or 30
    local syncEnabled = profile.pull and profile.pull.sync and profile.pull.sync.enabled
    if syncEnabled then
        local data = loadPullCoordinator()
        data.monks = data.monks or {}
        data.monks[charName] = {
            status = status,
            targetID = targetID,
            timestamp = os.time(),
        }
        for name, info in pairs(data.monks) do
            if os.time() - (info.timestamp or 0) > syncSeconds then
                data.monks[name] = nil
            end
        end
        savePullCoordinator(data)
    end
    registerTeamAction('pull', string.format('monk:%s', charName), syncSeconds, {
        status = status,
        targetID = targetID,
    })
end

local function otherMonkPulling()
    local profile = ensureProfile()
    if not profile.pull.sync.enabled then
        return false
    end
    local data = loadPullCoordinator()
    for name, info in pairs(data.monks or {}) do
        if name ~= charName and info.status == 'pulling' then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Camp helpers ---------------------------------------------------------------
--------------------------------------------------------------------------------
local function distanceToCamp(profile)
    if not profile.camp.anchor then return math.huge end
    local x = mq.TLO.Me.X() or 0
    local y = mq.TLO.Me.Y() or 0
    local anchor = profile.camp.anchor
    local dx = x - anchor.x
    local dy = y - anchor.y
    return math.sqrt(dx * dx + dy * dy)
end

local function ensureCamp(profile)
    if not profile.camp.enabled or not profile.camp.anchor then
        return
    end
    if mq.TLO.Me.CombatState() ~= 'COMBAT' then
        local dist = distanceToCamp(profile)
        if dist > (profile.camp.radius or 40) and profile.camp.returnToCamp then
            mq.cmdf('/nav locxyz %d %d %d', profile.camp.anchor.x, profile.camp.anchor.y, profile.camp.anchor.z)
            scriptState.statusText = 'Returning to camp'
        end
    end
end

--------------------------------------------------------------------------------
-- Pulling logic --------------------------------------------------------------
--------------------------------------------------------------------------------
local function findPullTarget(profile)
    local filter = string.format('npc radius %d zradius 50', profile.pull.radius or 120)
    local spawn = mq.TLO.NearestSpawn(filter)
    if spawn() and spawn.ID() > 0 then
        return spawn
    end
end

local function usePhantomShadow(profile)
    if not profile.pull.usePhantom then return end
    local aaID = profile.pull.phantomID or 968
    if mq.TLO.Me.AltAbilityReady(aaID)() then
        mq.cmdf('/alt activate %d', aaID)
        scriptState.pull.phantomUsed = true
    end
end

local function feignDeath(profile)
    local ability = profile.pull.feignAbility or 'Feign Death'
    if mq.TLO.Me.AbilityReady(ability)() then
        mq.cmdf('/doability "%s"', ability)
        scriptState.lastAction = ability
    end
end

local function pullReturnToCamp(profile)
    if not profile.camp.anchor then return end
    if scriptState.pull.usingNav then
        mq.cmd('/nav stop')
        mq.cmd('/nav clear')
        scriptState.pull.usingNav = false
    end
    mq.cmdf('/nav locxyz %d %d %d', profile.camp.anchor.x, profile.camp.anchor.y, profile.camp.anchor.z)
end

local function runPuller(profile)
    if not profile.pull.enabled then return end
    if classShort ~= 'MNK' then return end
    if mq.TLO.Me.CombatState() == 'COMBAT' then return end
    local xtargetCount = tonumber(mq.TLO.Me.XTarget() or 0)
    if xtargetCount >= (profile.pull.maxActive or 2) then return end
    if otherMonkPulling() then return end

    local state = scriptState.pull
    if state.state == 'idle' then
        local target = findPullTarget(profile)
        if target then
            state.state = 'pulling'
            state.targetID = target.ID()
            state.startTime = now()
            state.phantomUsed = false
            state.usingNav = false
            updatePullStatus('pulling', state.targetID)
            mq.cmdf('/target id %d', target.ID())
            mq.delay(50)
            usePhantomShadow(profile)
            local navCommand = profile.pull.navCommand
            if type(navCommand) == 'string' and navCommand:match('%S') then
                mq.cmdf(navCommand, target.ID())
                state.usingNav = true
            else
                mq.cmd('/stick 60 behind')
            end
            mq.cmd('/attack on')
            scriptState.statusText = string.format('Pulling %s', target.CleanName())
        end
    elseif state.state == 'pulling' then
        if not mq.TLO.Target() or mq.TLO.Target.ID() ~= state.targetID then
            if state.targetID then
                mq.cmdf('/target id %d', state.targetID)
                mq.delay(20)
            end
        end
        local currentXT = tonumber(mq.TLO.Me.XTarget() or 0)
        if currentXT > 1 and (mq.TLO.Me.PctHPs() or 100) < (profile.pull.feignPctHP or 35) then
            feignDeath(profile)
        end
        if profile.camp.anchor then
            local dist = distanceToCamp(profile)
            if dist > (profile.pull.minRange or 30) then
                pullReturnToCamp(profile)
            end
        end
        if mq.TLO.Target() and mq.TLO.Target.Distance() and mq.TLO.Target.Distance() < 35 then
            mq.cmd('/attack off')
            pullReturnToCamp(profile)
            state.state = 'returning'
            updatePullStatus('returning', state.targetID)
        end
    elseif state.state == 'returning' then
        if profile.camp.anchor then
            local dist = distanceToCamp(profile)
            if dist <= (profile.camp.radius or 40) then
                mq.cmd('/attack off')
                mq.cmd('/stick off')
                mq.cmd('/nav stop')
                mq.cmd('/nav clear')
                state.state = 'idle'
                state.targetID = nil
                state.usingNav = false
                updatePullStatus('idle', 0)
                scriptState.statusText = 'Pull complete'
            end
        else
            state.state = 'idle'
            state.usingNav = false
            updatePullStatus('idle', 0)
        end
    end
end

--------------------------------------------------------------------------------
-- Buffs/DPS/Heals/Utility ----------------------------------------------------
--------------------------------------------------------------------------------
local function runBuffs(profile)
    if not profile.general.buffs then return end
    if profile.buffs.outOfCombatOnly and mq.TLO.Me.CombatState() == 'COMBAT' then
        return
    end
    for _, entry in ipairs(profile.buffs.list or {}) do
        local targetToken = entry.target or 'self'
        local targetName = resolveTargetString(targetToken)
        if (not targetName or targetName == '' or targetToken == 'current' or targetToken == 'target') and mq.TLO.Target() then
            targetName = mq.TLO.Target.CleanName() or targetToken
        end
        local keyTarget = targetName or targetToken or charName
        if keyTarget == '' then keyTarget = charName end
        local descriptor = entry.name or entry.command or entry.type or 'entry'
        local shareKey = string.format('%s:%s', keyTarget, descriptor)
        processEntry(entry, profile, nil, {
            shareAction = {
                type = 'buff',
                key = shareKey,
                duration = entry.shareDuration or estimateActionDuration(entry),
                info = {target = keyTarget, spell = entry.name, entryType = entry.type},
            },
        })
    end
end

local function stickPluginActive()
    local stick = mq.TLO.Stick
    if not stick or not stick.Active then return nil end
    local ok, value = pcall(function() return stick.Active() end)
    if not ok then return nil end
    if type(value) == 'string' then
        local lowered = value:lower()
        if lowered == 'true' or lowered == 'on' then return true end
        if lowered == 'false' or lowered == 'off' then return false end
        local number = tonumber(lowered)
        if number ~= nil then return number ~= 0 end
        return lowered ~= ''
    elseif type(value) == 'number' then
        return value ~= 0
    end
    return not not value
end

local function clearStick()
    if scriptState.stick.active or stickPluginActive() then
        mq.cmd('/stick off')
    end
    scriptState.stick.active = false
    scriptState.stick.targetID = 0
end

local function issueStickCommand(assist, targetID)
    local distance = tonumber(assist.stickDist) or 10
    if distance < 0 then distance = 0 end
    distance = math.floor(distance + 0.5)
    if distance < 1 then distance = 1 end
    local mode = (assist.stickMode or 'behind'):lower()
    if mode == 'hold' then
        mq.cmdf('/stick hold %d', distance)
    elseif mode == 'front' then
        mq.cmdf('/stick %d front', distance)
    else
        mq.cmdf('/stick %d behind', distance)
    end
    scriptState.stick.active = true
    scriptState.stick.targetID = targetID
end

local function updateAssistStick(assist, targetID)
    assist = assist or {}
    local stickEnabled = assist.stick ~= false
    local breakOnLoss = assist.stickBreakOnTargetLoss ~= false

    local pluginActive = stickPluginActive()
    if pluginActive == false and scriptState.stick.active then
        scriptState.stick.active = false
        scriptState.stick.targetID = 0
    end

    if not stickEnabled then
        if scriptState.stick.active or pluginActive then
            clearStick()
        end
        return
    end

    if not targetID or targetID == 0 then
        if breakOnLoss then
            clearStick()
        end
        return
    end

    if scriptState.stick.targetID ~= targetID or not scriptState.stick.active then
        if scriptState.stick.active then
            clearStick()
        end
        issueStickCommand(assist, targetID)
        return
    end

    if pluginActive then
        scriptState.stick.active = true
        scriptState.stick.targetID = targetID
    end
end

local function currentTargetID()
    local target = mq.TLO.Target
    if not target then return 0 end
    local id = target.ID and target.ID() or 0
    if not id or id == 0 then return 0 end
    if target.Type and target.Type() == 'Corpse' then return 0 end
    return id
end

local function assistTarget(profile)
    local assist = profile.general.assist or {}
    if not assist.enabled then
        updateAssistStick(assist, 0)
        return
    end

    local targetID = currentTargetID()
    local attemptedAssist = false
    if targetID == 0 then
        if assist.mode == 'manual' and assist.target and assist.target ~= '' then
            mq.cmdf('/assist %s', assist.target)
            attemptedAssist = true
        elseif assist.mode == 'xtar' then
            local slot = tonumber(assist.xtarSlot) or 1
            slot = math.max(1, math.floor(slot))
            mq.cmdf('/xtar %d', slot)
            attemptedAssist = true
        elseif assist.mode == 'mainassist' then
            local ma = mq.TLO.Group.MainAssist
            if ma and ma() and ma() ~= '' then
                mq.cmdf('/assist %s', ma())
                attemptedAssist = true
            end
        end
        if attemptedAssist then
            mq.delay(50)
            targetID = currentTargetID()
        end
    end

    updateAssistStick(assist, targetID)
end

local function runDPS(profile)
    if not profile.general.dps then return end
    assistTarget(profile)
    local targetTLO = mq.TLO.Target
    local targetID = 0
    if targetTLO and targetTLO() then
        targetID = (targetTLO.ID and targetTLO.ID()) or 0
    end
    local hasTarget = targetID > 0
    if profile.dps.rotation then
        iterateList(profile.dps.rotation, profile, {Target = targetTLO})
    end
    local burnAction = teamActionInProgress('burn', 'global')
    if profile.dps.burns and profile.dps.burns.enabled then
        local shouldBurn = false
        local trigger = profile.dps.burns.trigger or 35
        if hasTarget then
            local targetHP = targetTLO.PctHPs()
            if targetHP and targetHP <= trigger then
                shouldBurn = true
                if not burnAction or burnAction.by ~= charName then
                    registerTeamAction('burn', 'global', profile.dps.burns.duration or 20, {
                        trigger = trigger,
                        targetID = targetID,
                        targetName = targetTLO.CleanName() or '',
                    })
                    burnAction = teamActionInProgress('burn', 'global')
                end
            end
        end
        if not shouldBurn and burnAction and os.time() < (burnAction.expires or 0) then
            local info = burnAction.info or {}
            if not info.targetID or info.targetID == 0 then
                shouldBurn = hasTarget
            elseif hasTarget and info.targetID == targetID then
                shouldBurn = true
            end
        end
        if shouldBurn and hasTarget then
            iterateList(profile.dps.burns.abilities, profile, {Target = targetTLO})
        end
    end
end

local function runHeals(profile)
    if not profile.general.heals then return end
    local meHP = mq.TLO.Me.PctHPs() or 100
    local selfHeal = profile.heals.self
    if selfHeal and selfHeal.enabled and meHP <= (selfHeal.threshold or 40) then
        processEntry(selfHeal.entry, profile, nil, {
            shareAction = {
                type = 'heal',
                key = string.format('%s:%s', charName, selfHeal.entry.name or 'self'),
                duration = estimateActionDuration(selfHeal.entry),
                info = {target = charName, mode = 'self'},
                allowOverlap = true,
            },
        })
    end
    for _, heal in ipairs(profile.heals.group or {}) do
        if heal.enabled then
            local spawn = mq.TLO.Spawn(string.format('pc %s', heal.target or ''))
            local hp
            if heal.target == 'maintank' then
                local mt = mq.TLO.Group.MainTank
                if mt and mt() and mt() ~= '' then
                    spawn = mq.TLO.Spawn(string.format('pc %s', mt()))
                end
            elseif heal.target and heal.target ~= '' then
                spawn = mq.TLO.Spawn(string.format('pc %s', heal.target))
            end
            if spawn() then
                hp = spawn.PctHPs()
            end
            if hp and hp <= (heal.threshold or 60) then
                local targetName = heal.target or 'unknown'
                if spawn() then
                    targetName = spawn.CleanName() or targetName
                end
                local shareKey = string.format('%s:%s', targetName, heal.entry.name or 'heal')
                processEntry(heal.entry, profile, {Target = spawn}, {
                    shareAction = {
                        type = 'heal',
                        key = shareKey,
                        duration = heal.shareDuration or estimateActionDuration(heal.entry),
                        info = {target = targetName, threshold = heal.threshold, spell = heal.entry.name},
                    },
                })
            end
        end
    end
end

local function runUtility(profile)
    if not profile.general.utility then return end
    iterateList(profile.utility.clickies, profile)
    if profile.utility.evac.enabled and evaluateCondition(profile.utility.evac.condition, profile) then
        local evacSpell = profile.utility.evac.spell
        if evacSpell and evacSpell ~= '' then
            local entry = {type = 'Spell', name = evacSpell, gem = profile.utility.evac.gem or 1}
            processEntry(entry, profile, nil, {
                shareAction = {
                    type = 'utility',
                    key = string.format('evac:%s', evacSpell),
                    duration = profile.utility.evac.shareDuration or estimateActionDuration(entry),
                    info = {spell = evacSpell, reason = 'evac'},
                },
            })
        end
    end
end

local function runCustom(profile)
    for _, entry in ipairs(profile.custom.entries or {}) do
        if entry.enabled ~= false and evaluateCondition(entry.condition, profile) then
            local cooldown = (entry.cooldown or 0) * 1000
            local last = entry.lastExecution or 0
            if now() - last >= cooldown then
                for command in (entry.commands or ''):gmatch('[^;\n]+') do
                    local trimmed = command:gsub('^%s+', ''):gsub('%s+$', '')
                    if trimmed ~= '' then
                        mq.cmd(trimmed)
                    end
                end
                entry.lastExecution = now()
                if entry.stopAfter then
                    break
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Configuration persistence ---------------------------------------------------
--------------------------------------------------------------------------------
local function loadConfig()
    local data = loadTable(configFile)
    if data then
        mergeTable(config, data)
    end
    ensureProfile()
end

local function saveConfig()
    config.lastSave = now()
    saveTable(configFile, config)
    printf('INFO', 'Configuration saved to %s', configFile)
end

--------------------------------------------------------------------------------
-- UI helpers -----------------------------------------------------------------
--------------------------------------------------------------------------------
local abilityTypes = {'Spell', 'AA', 'Disc', 'Item', 'Command', 'Ability'}

local assistModes = {'manual', 'xtar', 'mainassist'}
local stickModes = {'behind', 'front', 'hold'}

local function typeIndex(current)
    for i, v in ipairs(abilityTypes) do
        if v == current then return i end
    end
    return 1
end

local function listIndex(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return 1
end

local function renderEntryEditor(label, list)
    if ImGui.TreeNode(label) then
        local removeIndex
        for idx, entry in ipairs(list) do
            ImGui.PushID(label .. idx)
            local enabled = entry.enabled ~= false
            local changed, value = ImGui.Checkbox('Enabled##' .. idx, enabled)
            if changed then entry.enabled = value end
            changed, entry.name = ImGui.InputText('Name##' .. idx, entry.name or '')
            local currentType = typeIndex(entry.type or 'Spell')
            changed, currentType = ImGui.Combo('Type##' .. idx, currentType - 1, abilityTypes, #abilityTypes)
            entry.type = abilityTypes[currentType + 1]
            changed, entry.target = ImGui.InputText('Target##' .. idx, entry.target or '')
            changed, entry.condition = ImGui.InputText('Condition##' .. idx, entry.condition or '')
            local cooldown = entry.cooldown or 0
            changed, cooldown = ImGui.InputInt('Cooldown##' .. idx, cooldown)
            if changed then entry.cooldown = cooldown end
            if entry.type == 'Spell' then
                local gem = entry.gem or 1
                changed, gem = ImGui.InputInt('Gem##' .. idx, gem)
                if changed then entry.gem = gem end
            elseif entry.type == 'AA' then
                local aaID = entry.id or 0
                changed, aaID = ImGui.InputInt('AA ID##' .. idx, aaID)
                if changed then entry.id = aaID end
            elseif entry.type == 'Command' then
                changed, entry.command = ImGui.InputText('Command##' .. idx, entry.command or '')
            end
            if ImGui.Button('Remove##' .. idx) then
                removeIndex = idx
            end
            ImGui.Separator()
            ImGui.PopID()
        end
        if removeIndex then table.remove(list, removeIndex) end
        if ImGui.Button('Add##' .. label) then
            table.insert(list, {type = 'Spell', name = '', cooldown = 0})
        end
        ImGui.TreePop()
    end
end

local function renderCustomRules(profile)
    if ImGui.TreeNode('Custom Rules') then
        local remove
        for idx, entry in ipairs(profile.custom.entries) do
            ImGui.PushID('custom' .. idx)
            local enabled = entry.enabled ~= false
            local changed, value = ImGui.Checkbox('Enabled##custom' .. idx, enabled)
            if changed then entry.enabled = value end
            changed, entry.label = ImGui.InputText('Label##' .. idx, entry.label or '')
            changed, entry.condition = ImGui.InputTextMultiline('Condition##' .. idx, entry.condition or '', 250, 60)
            changed, entry.commands = ImGui.InputTextMultiline('Commands##' .. idx, entry.commands or '', 250, 80)
            local cooldown = entry.cooldown or 0
            changed, cooldown = ImGui.InputFloat('Cooldown (s)##' .. idx, cooldown)
            if changed then entry.cooldown = cooldown end
            local stopAfter = entry.stopAfter or false
            changed, stopAfter = ImGui.Checkbox('Stop processing after run##' .. idx, stopAfter)
            if changed then entry.stopAfter = stopAfter end
            if ImGui.Button('Remove##custom' .. idx) then
                remove = idx
            end
            ImGui.Separator()
            ImGui.PopID()
        end
        if remove then table.remove(profile.custom.entries, remove) end
        if ImGui.Button('Add Custom Rule') then
            table.insert(profile.custom.entries, {label = 'New Rule', condition = '', commands = '', cooldown = 0})
        end
        ImGui.TreePop()
    end
end

local function renderCampSettings(profile)
    if ImGui.TreeNode('Camp Settings') then
        local enabled = profile.camp.enabled
        local changed
        changed, enabled = ImGui.Checkbox('Camp Enabled', enabled)
        if changed then profile.camp.enabled = enabled end
        local radius = profile.camp.radius or 40
        changed, radius = ImGui.InputFloat('Radius', radius)
        if changed then profile.camp.radius = radius end
        changed, profile.camp.returnToCamp = ImGui.Checkbox('Return to Camp', profile.camp.returnToCamp)
        changed, profile.camp.leashing = ImGui.Checkbox('Leash Movement', profile.camp.leashing)
        if profile.camp.anchor then
            ImGui.Text(string.format('Anchor: %.1f, %.1f, %.1f', profile.camp.anchor.x, profile.camp.anchor.y, profile.camp.anchor.z))
            if ImGui.Button('Clear Camp') then profile.camp.anchor = nil end
        else
            ImGui.Text('No camp set')
        end
        if ImGui.Button('Set Camp to Current Location') then
            profile.camp.anchor = {x = mq.TLO.Me.X() or 0, y = mq.TLO.Me.Y() or 0, z = mq.TLO.Me.Z() or 0}
        end
        ImGui.TreePop()
    end
end

local function renderPullSettings(profile)
    if ImGui.TreeNode('Pull Settings') then
        local enabled = profile.pull.enabled
        local changed
        changed, enabled = ImGui.Checkbox('Pull Enabled', enabled)
        if changed then profile.pull.enabled = enabled end
        changed, profile.pull.radius = ImGui.InputFloat('Pull Radius', profile.pull.radius or 120)
        changed, profile.pull.minRange = ImGui.InputFloat('Min Camp Distance', profile.pull.minRange or 30)
        changed, profile.pull.maxActive = ImGui.InputInt('Max Active Mobs', profile.pull.maxActive or 2)
        changed, profile.pull.usePhantom = ImGui.Checkbox('Use Phantom Shadow', profile.pull.usePhantom)
        changed, profile.pull.phantomID = ImGui.InputInt('Phantom AA ID', profile.pull.phantomID or 968)
        changed, profile.pull.feignAbility = ImGui.InputText('Feign Ability', profile.pull.feignAbility or 'Feign Death')
        changed, profile.pull.feignPctHP = ImGui.InputFloat('Feign HP %', profile.pull.feignPctHP or 35)
        changed, profile.pull.sync.enabled = ImGui.Checkbox('Coordinate Monks', profile.pull.sync.enabled)
        changed, profile.pull.sync.staleSeconds = ImGui.InputInt('Sync Timeout', profile.pull.sync.staleSeconds or 30)
        ImGui.TreePop()
    end
end

local function renderCharmSettings(profile)
    local specials = profile.specials or {}
    local charm = specials.charm
    if not charm then return false end
    ImGui.Separator()
    ImGui.Text('Charm Control')
    local changed
    changed, charm.enabled = ImGui.Checkbox('Enable Charm', charm.enabled)
    changed, charm.spell = ImGui.InputText('Charm Spell', charm.spell or '')
    local gem = charm.gem or 1
    changed, gem = ImGui.InputInt('Charm Gem', gem)
    if changed then charm.gem = gem end
    changed, charm.targetFilter = ImGui.InputText('Target Filter', charm.targetFilter or '')
    local breakHP = charm.breakHP or 25
    changed, breakHP = ImGui.InputFloat('Break HP %', breakHP)
    if changed then
        if breakHP < 0 then breakHP = 0 end
        if breakHP > 100 then breakHP = 100 end
        charm.breakHP = breakHP
    end
    local rebreak = charm.rebreak ~= false
    changed, rebreak = ImGui.Checkbox('Recharm on Break', rebreak)
    if changed then charm.rebreak = rebreak end
    local delay = charm.recharmDelay or 2.0
    changed, delay = ImGui.InputFloat('Recharm Cooldown (s)', delay)
    if changed then charm.recharmDelay = math.max(delay, 0) end
    local suppress = charm.suppressSeconds or 6.0
    changed, suppress = ImGui.InputFloat('Suppress After Release (s)', suppress)
    if changed then charm.suppressSeconds = math.max(suppress, 0) end
    local mezOnBreak = charm.mezOnBreak or false
    changed, mezOnBreak = ImGui.Checkbox('Mez on Break', mezOnBreak)
    if changed then charm.mezOnBreak = mezOnBreak end
    changed, charm.mezzSpell = ImGui.InputText('Mez Spell', charm.mezzSpell or '')
    local mezzGem = charm.mezzGem or 1
    changed, mezzGem = ImGui.InputInt('Mez Gem', mezzGem)
    if changed then charm.mezzGem = math.max(mezzGem, 1) end
    changed, charm.condition = ImGui.InputText('Charm Condition', charm.condition or '')
    return true
end

local function renderSpecialSettings(profile)
    if ImGui.TreeNode('Special Class Features') then
        local hadContent = false
        if renderCharmSettings(profile) then
            hadContent = true
        end
        if classShort == 'SHM' then
            local cann = profile.specials.cannibalize or {enabled = false}
            profile.specials.cannibalize = cann
            local changed
            changed, cann.enabled = ImGui.Checkbox('Enable Cannibalization', cann.enabled)
            changed, cann.ability = ImGui.InputText('Ability', cann.ability or 'Cannibalization')
            changed, cann.type = ImGui.InputText('Type (Spell/AA/Ability)', cann.type or 'AA')
            local mana = cann.manaBelow or 80
            changed, mana = ImGui.InputFloat('Use Below Mana %', mana)
            if changed then cann.manaBelow = mana end
            local hp = cann.minHP or 60
            changed, hp = ImGui.InputFloat('Keep HP Above %', hp)
            if changed then cann.minHP = hp end
            changed, cann.announce = ImGui.Checkbox('Announce', cann.announce or false)
            hadContent = true
        elseif classShort == 'PAL' then
            local loh = profile.specials.layHands or {enabled = false}
            profile.specials.layHands = loh
            local changed
            changed, loh.enabled = ImGui.Checkbox('Enable Lay on Hands', loh.enabled)
            changed, loh.target = ImGui.InputText('Target', loh.target or 'maintank')
            local threshold = loh.threshold or 25
            changed, threshold = ImGui.InputFloat('HP Threshold', threshold)
            if changed then loh.threshold = threshold end
            changed, loh.command = ImGui.InputText('Command', loh.command or '/alt activate 2000')
            changed, loh.announce = ImGui.InputText('Announce', loh.announce or '')
            hadContent = true
        elseif classShort == 'ROG' then
            local sa = profile.specials.sneakAttack or {enabled = false}
            profile.specials.sneakAttack = sa
            local changed
            changed, sa.enabled = ImGui.Checkbox('Enable Sneak Attack', sa.enabled)
            changed, sa.ability = ImGui.InputText('Sneak Ability', sa.ability or 'Sneak Attack')
            changed, sa.backstab = ImGui.InputText('Backstab Ability', sa.backstab or 'Backstab')
            local cd = sa.cooldown or 12
            changed, cd = ImGui.InputFloat('Cooldown', cd)
            if changed then sa.cooldown = cd end
            hadContent = true
        elseif classShort == 'CLR' then
            local chain = profile.specials.chChain or {enabled = false}
            profile.specials.chChain = chain
            local changed
            changed, chain.enabled = ImGui.Checkbox('Enable CH Chain', chain.enabled)
            changed, chain.spell = ImGui.InputText('Spell', chain.spell or 'Complete Heal')
            local interval = chain.interval or 3
            changed, interval = ImGui.InputFloat('Interval (s)', interval)
            if changed then chain.interval = interval end
            local order = chain.order or 1
            changed, order = ImGui.InputInt('Chain Order', order)
            if changed then chain.order = order end
            local size = chain.chainSize or 3
            changed, size = ImGui.InputInt('Chain Size', size)
            if changed then chain.chainSize = size end
            changed, chain.channel = ImGui.InputText('Announce Channel', chain.channel or '/rs')
            changed, chain.message = ImGui.InputText('Announce Message', chain.message or 'CH %s (#%d/%d)')
            hadContent = true
        end
        if not hadContent then
            ImGui.Text('No special configuration for this class yet.')
        end
        ImGui.TreePop()
    end
end

local function renderGeneralSettings(profile)
    ImGui.Text(string.format('Class: %s (%s)', classLong, classShort))
    ImGui.Text(string.format('Status: %s', scriptState.statusText))
    if ImGui.Button(scriptState.paused and 'Resume' or 'Pause') then
        scriptState.paused = not scriptState.paused
    end
    ImGui.SameLine()
    if ImGui.Button(scriptState.showUI and 'Hide UI' or 'Show UI') then
        scriptState.showUI = not scriptState.showUI
    end
    ImGui.SameLine()
    if ImGui.Button('Save Config') then
        saveConfig()
    end
    local toggles = profile.general
    if ImGui.TreeNode('Automation Toggles') then
        local changed
        changed, toggles.buffs = ImGui.Checkbox('Buffs', toggles.buffs)
        changed, toggles.dps = ImGui.Checkbox('DPS', toggles.dps)
        changed, toggles.heals = ImGui.Checkbox('Heals', toggles.heals)
        changed, toggles.utility = ImGui.Checkbox('Utility', toggles.utility)
        changed, toggles.specials = ImGui.Checkbox('Specials', toggles.specials)
        ImGui.TreePop()
    end
    if ImGui.TreeNode('Assist Settings') then
        local assist = profile.general.assist or {}
        profile.general.assist = assist
        local changed
        local assistEnabled = assist.enabled ~= false
        changed, assistEnabled = ImGui.Checkbox('Assist Enabled', assistEnabled)
        if changed then assist.enabled = assistEnabled end
        local currentMode = listIndex(assistModes, assist.mode or 'manual') - 1
        changed, currentMode = ImGui.Combo('Assist Mode', currentMode, assistModes, #assistModes)
        if changed then assist.mode = assistModes[currentMode + 1] end
        if assist.mode == 'manual' then
            changed, assist.target = ImGui.InputText('Assist Target', assist.target or '')
        elseif assist.mode == 'xtar' then
            local slot = assist.xtarSlot or 1
            changed, slot = ImGui.InputInt('XTarget Slot', slot)
            if changed then assist.xtarSlot = math.max(1, math.floor(slot)) end
        end
        local stickEnabled = assist.stick ~= false
        changed, stickEnabled = ImGui.Checkbox('Use Stick', stickEnabled)
        if changed then assist.stick = stickEnabled end
        local distance = assist.stickDist or 10
        changed, distance = ImGui.InputFloat('Stick Distance', distance)
        if changed then
            if distance < 0 then distance = 0 end
            assist.stickDist = distance
        end
        local currentStickMode = listIndex(stickModes, (assist.stickMode or 'behind')) - 1
        changed, currentStickMode = ImGui.Combo('Stick Mode', currentStickMode, stickModes, #stickModes)
        if changed then assist.stickMode = stickModes[currentStickMode + 1] end
        local breakStick = assist.stickBreakOnTargetLoss ~= false
        changed, breakStick = ImGui.Checkbox('Break Stick Without Target', breakStick)
        if changed then assist.stickBreakOnTargetLoss = breakStick end
        ImGui.TreePop()
    end
end

local function renderUI()
    if not scriptState.showUI then return end
    local profile = ensureProfile()
    if ImGui.Begin('All-In-One Controller', scriptState.showUI) then
        renderGeneralSettings(profile)
        if ImGui.CollapsingHeader('Buffs') then
            renderEntryEditor('Buff List', profile.buffs.list)
        end
        if ImGui.CollapsingHeader('DPS & Burns') then
            renderEntryEditor('Rotation', profile.dps.rotation)
            renderEntryEditor('Burn Abilities', profile.dps.burns.abilities)
        end
        if ImGui.CollapsingHeader('Heals') then
            if ImGui.TreeNode('Self Heal') then
                local selfEntry = profile.heals.self.entry
                local enabled = profile.heals.self.enabled
                local changed
                changed, enabled = ImGui.Checkbox('Enabled##self', enabled)
                profile.heals.self.enabled = enabled
                changed, selfEntry.name = ImGui.InputText('Spell##self', selfEntry.name or '')
                changed, selfEntry.gem = ImGui.InputInt('Gem##self', selfEntry.gem or 1)
                ImGui.TreePop()
            end
            renderEntryEditor('Group Heals', profile.heals.group)
        end
        if ImGui.CollapsingHeader('Utility & Clickies') then
            renderEntryEditor('Clickies', profile.utility.clickies)
        end
        if ImGui.CollapsingHeader('Custom Logic') then
            renderCustomRules(profile)
        end
        if ImGui.CollapsingHeader('Camp') then
            renderCampSettings(profile)
        end
        if ImGui.CollapsingHeader('Pulling') then
            renderPullSettings(profile)
        end
        if ImGui.CollapsingHeader('Specials') then
            renderSpecialSettings(profile)
        end
    end
    ImGui.End()
end

mq.imgui.init('AllInOneUI', renderUI)

--------------------------------------------------------------------------------
-- Command handling -----------------------------------------------------------
--------------------------------------------------------------------------------
local function printHelp()
    printf('INFO', '/aio pause|resume|toggleui|save|camp set|camp clear|pull on|pull off')
end

local function handleCommand(line)
    local args = {}
    for token in line:gmatch('%S+') do table.insert(args, token:lower()) end
    local cmd = args[1]
    if not cmd or cmd == 'help' then
        printHelp()
        return
    end
    local profile = ensureProfile()
    if cmd == 'pause' then
        scriptState.paused = true
    elseif cmd == 'resume' then
        scriptState.paused = false
    elseif cmd == 'toggleui' or cmd == 'ui' then
        scriptState.showUI = not scriptState.showUI
    elseif cmd == 'save' then
        saveConfig()
    elseif cmd == 'camp' then
        local action = args[2]
        if action == 'set' then
            profile.camp.anchor = {x = mq.TLO.Me.X() or 0, y = mq.TLO.Me.Y() or 0, z = mq.TLO.Me.Z() or 0}
            profile.camp.enabled = true
            printf('INFO', 'Camp anchored at current location.')
        elseif action == 'clear' then
            profile.camp.anchor = nil
            profile.camp.enabled = false
            printf('INFO', 'Camp cleared.')
        end
    elseif cmd == 'pull' then
        local action = args[2]
        if action == 'on' then
            profile.pull.enabled = true
            printf('INFO', 'Pulling enabled.')
        elseif action == 'off' then
            profile.pull.enabled = false
            printf('INFO', 'Pulling disabled.')
        end
    else
        printHelp()
    end
end

mq.bind('/aio', handleCommand)

--------------------------------------------------------------------------------
-- Main loop ------------------------------------------------------------------
--------------------------------------------------------------------------------
local function shouldRest(profile)
    local mana = mq.TLO.Me.PctMana() or 100
    local hp = mq.TLO.Me.PctHPs() or 100
    local endurance = mq.TLO.Me.PctEndurance() or 100
    return mana < (profile.general.restMana or 60) or hp < (profile.general.restHP or 80) or endurance < (profile.general.restEndurance or 40)
end

local function mainLoop()
    loadConfig()
    printf('INFO', 'All-In-One controller v%s loaded for %s (%s).', version, charName, classShort)
    local profile = ensureProfile()
    while scriptState.running do
        mq.doevents()
        mq.delay(50)
        if scriptState.paused then
            scriptState.statusText = 'Paused'
        else
            profile = ensureProfile()
            runCustom(profile)
            ensureCamp(profile)
            runPuller(profile)
            updateCHChain(profile)
            if mq.TLO.Me.Combat() then
                scriptState.statusText = 'Combat'
                runHeals(profile)
                runDPS(profile)
                runUtility(profile)
            else
                if shouldRest(profile) then
                    scriptState.statusText = 'Resting'
                else
                    scriptState.statusText = 'Active'
                end
                runBuffs(profile)
                runHeals(profile)
                runUtility(profile)
                runDPS(profile)
            end
            handleSpecials(profile)
        end
        updateTeamStatus(profile)
        if config.general.autoSave and now() - (config.lastSave or 0) > (config.general.saveInterval or 300) * 1000 then
            saveConfig()
        end
    end
end

mainLoop()

mq.onunload(function()
    scriptState.running = false
    removeTeamStatus()
    saveConfig()
end)

