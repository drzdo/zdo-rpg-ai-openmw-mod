-- ZDORPG Global Script
-- Handles IPC polling, command dispatch, world state tracking

local core = require('openmw.core')
local types = require('openmw.types')
local util = require('openmw.util')
local vfs = require('openmw.vfs')
local world = require('openmw.world')

local ipc = require('scripts.zdorpgai.ipc')

-- State
local POLL_INTERVAL_FRAMES = 5
local frameCounter = 0
local lastSeenClientMsgId = -1
local modMsgCounter = 0
local lastCellName = nil
local playerObject = nil
local activeNpcs = {}
local clientConnected = false

-------------------------------------------------------------------------------
-- Outgoing helpers
-------------------------------------------------------------------------------

local function publish(msgType, data)
    modMsgCounter = ipc.sendMessage(msgType, data, nil, modMsgCounter)
end

local function respond(msgType, responseTo, data)
    modMsgCounter = ipc.sendMessage(msgType, data, responseTo, modMsgCounter)
end

-------------------------------------------------------------------------------
-- Character info gathering
-------------------------------------------------------------------------------

local function getCharacterInfo(gameObject)
    local ok, record = pcall(types.NPC.record, gameObject)
    if not ok or not record then return nil end

    local health = types.Actor.stats.dynamic.health(gameObject)

    return {
        objectId = gameObject.recordId,
        name = record.name,
        race = record.race,
        sex = record.isMale and 'male' or 'female',
        isDead = types.Actor.isDead(gameObject),
        healthCurrent = health.current,
        healthMax = health.base,
    }
end

-------------------------------------------------------------------------------
-- Incoming message handlers
-------------------------------------------------------------------------------

local function handleGetPlayerInfo(msg)
    if not playerObject then
        respond('GetPlayerInfo', msg.id, { error = 'no_player' })
        return
    end
    local info = getCharacterInfo(playerObject)
    if not info then
        respond('GetPlayerInfo', msg.id, { error = 'info_failed' })
        return
    end
    respond('GetPlayerInfo', msg.id, {
        objectId = info.objectId,
        name = info.name,
        race = info.race,
        sex = info.sex,
    })
end

local function handleGetNpcInfo(msg)
    local data = msg.data or {}
    if not data.npcId then
        respond('GetNpcInfo', msg.id, { error = 'missing_npcId' })
        return
    end
    local npc = activeNpcs[data.npcId]
    if not npc then
        respond('GetNpcInfo', msg.id, { error = 'not_found' })
        return
    end
    local info = getCharacterInfo(npc)
    if not info then
        respond('GetNpcInfo', msg.id, { error = 'info_failed' })
        return
    end
    respond('GetNpcInfo', msg.id, {
        objectId = info.objectId,
        name = info.name,
        race = info.race,
        sex = info.sex,
    })
end

local function handleSayMp3File(msg)
    local data = msg.data or {}
    local npc = activeNpcs[data.npcId]
    if not npc then return end
    local okSay, err = pcall(core.sound.say, 'zdorpgai_mp3/' .. data.mp3Name, npc, '')
    if not okSay then
        print('[ZDORPG] Error playing voice: ' .. tostring(err))
    end
    if playerObject and data.text and data.text ~= '' then
        local npcName = data.npcId or '???'
        local okRec, record = pcall(types.NPC.record, npc)
        if okRec and record then
            npcName = record.name
        end
        playerObject:sendEvent('ZdorpgShowSpeech', {
            npcName = npcName,
            text = data.text,
            animate = true,
            durationSec = data.durationSec,
        })
    end
end

local function handleSpeechRecognitionInProgress(msg)
    if not playerObject then return end
    local data = msg.data or {}
    playerObject:sendEvent('ZdorpgShowListening', {
        text = data.text or '',
    })
end

local function handleSpeechRecognitionComplete(msg)
    if not playerObject then return end
    local data = msg.data or {}
    playerObject:sendEvent('ZdorpgShowListening', {
        text = data.text or '',
    })
end

local function handlePlayerStartSpeak(msg)
    if playerObject then
        playerObject:sendEvent('ZdorpgShowListening', {})
    end
end

local function handlePlayerStopSpeak(msg)
    -- Don't hide listening here; let SpeechRecognitionComplete or the
    -- 4-second auto-hide timer handle it instead.
end

local function showConnectedIndicator()
    if playerObject then
        playerObject:sendEvent('ZdorpgNotify', { text = 'ZdoRPG connected' })
    end
end

local function handleStartSession(msg)
    clientConnected = true
    print('[ZDORPG] Client connected')
    showConnectedIndicator()
end

local function handleGetCharactersWhoHear(msg)
    local data = msg.data or {}
    local characterId = data.characterId
    if not characterId then
        respond('GetCharactersWhoHear', msg.id, { characters = {} })
        return
    end

    -- Find the speaking character
    local speaker = nil
    if playerObject and playerObject.recordId == characterId then
        speaker = playerObject
    else
        speaker = activeNpcs[characterId]
    end

    if not speaker then
        respond('GetCharactersWhoHear', msg.id, { characters = {} })
        return
    end

    local okPos, speakerPos = pcall(function() return speaker.position end)
    if not okPos or not speakerPos then
        respond('GetCharactersWhoHear', msg.id, { characters = {} })
        return
    end

    local hearingRangeSq = 2000 * 2000
    local characters = {}
    for id, npc in pairs(activeNpcs) do
        if id ~= characterId then
            local okDead, isDead = pcall(types.Actor.isDead, npc)
            if okDead and not isDead then
                local okNpc, npcPos = pcall(function() return npc.position end)
                if okNpc and npcPos then
                    local dx = npcPos.x - speakerPos.x
                    local dy = npcPos.y - speakerPos.y
                    local dz = npcPos.z - speakerPos.z
                    local distSq = dx*dx + dy*dy + dz*dz
                    if distSq < hearingRangeSq then
                        characters[#characters + 1] = { characterId = id, distance = math.sqrt(distSq) }
                    end
                end
            end
        end
    end

    table.sort(characters, function(a, b) return a.distance < b.distance end)
    respond('GetCharactersWhoHear', msg.id, { characters = characters })
end

local function handleSpawnOnGroundInFrontOfCharacter(msg)
    local data = msg.data or {}
    local npcId = data.npcId
    local itemId = data.itemId
    local count = data.count or 1

    if not npcId or not itemId then
        print('[ZDORPG] SpawnOnGround: missing npcId or itemId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] SpawnOnGround: NPC not found: ' .. tostring(npcId))
        return
    end

    local okPos, npcPos = pcall(function() return npc.position end)
    if not okPos or not npcPos then
        print('[ZDORPG] SpawnOnGround: cannot get NPC position')
        return
    end

    local okRot, facing = pcall(function() return npc.rotation:getYaw() end)
    if not okRot then
        facing = 0
    end

    local spawnDistance = 70
    local spawnPos = util.vector3(
        npcPos.x + math.sin(facing) * spawnDistance,
        npcPos.y + math.cos(facing) * spawnDistance,
        npcPos.z
    )

    local okCreate, item = pcall(world.createObject, itemId, count)
    if not okCreate or not item then
        print('[ZDORPG] SpawnOnGround: failed to create ' .. tostring(itemId) .. ': ' .. tostring(item))
        return
    end

    local okBB, bb = pcall(function() return item:getBoundingBox() end)
    if okBB and bb then
        spawnPos = util.vector3(spawnPos.x, spawnPos.y, spawnPos.z + bb.halfSize.z)
    end

    local okTeleport, err = pcall(function()
        item:teleport(npc.cell, spawnPos)
    end)
    if not okTeleport then
        print('[ZDORPG] SpawnOnGround: failed to place object: ' .. tostring(err))
        return
    end

    print('[ZDORPG] Spawned ' .. tostring(count) .. 'x ' .. tostring(itemId) .. ' in front of ' .. tostring(npcId))
end

local function handlePlaySound3dOnCharacter(msg)
    local data = msg.data or {}
    local npcId = data.npcId
    local sound = data.sound

    if not npcId or not sound then
        print('[ZDORPG] PlaySound3d: missing npcId or sound')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] PlaySound3d: NPC not found: ' .. tostring(npcId))
        return
    end

    local ok, err = pcall(core.sound.playSound3d, sound, npc)
    if not ok then
        print('[ZDORPG] PlaySound3d: failed to play ' .. tostring(sound) .. ': ' .. tostring(err))
    end
end

local function handleNpcStartFollowCharacter(msg)
    local data = msg.data or {}
    local npcId = data.npcId
    local targetId = data.targetCharacterId

    if not npcId or not targetId then
        print('[ZDORPG] NpcStartFollow: missing npcId or targetCharacterId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] NpcStartFollow: NPC not found: ' .. tostring(npcId))
        return
    end

    local target = activeNpcs[targetId]
    if not target then
        if playerObject and playerObject.recordId == targetId then
            target = playerObject
        else
            print('[ZDORPG] NpcStartFollow: target not found: ' .. tostring(targetId))
            return
        end
    end

    local ok, err = pcall(function()
        npc:sendEvent('RemoveAIPackages', 'Follow')
        npc:sendEvent('StartAIPackage', {type = 'Follow', target = target})
    end)
    if not ok then
        print('[ZDORPG] NpcStartFollow: failed: ' .. tostring(err))
        return
    end

    print('[ZDORPG] NPC ' .. tostring(npcId) .. ' now following ' .. tostring(targetId))
end

local function handleNpcStopFollowCharacter(msg)
    local data = msg.data or {}
    local npcId = data.npcId

    if not npcId then
        print('[ZDORPG] NpcStopFollow: missing npcId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] NpcStopFollow: NPC not found: ' .. tostring(npcId))
        return
    end

    local ok, err = pcall(function()
        npc:sendEvent('RemoveAIPackages', 'Follow')
    end)
    if not ok then
        print('[ZDORPG] NpcStopFollow: failed: ' .. tostring(err))
        return
    end

    print('[ZDORPG] NPC ' .. tostring(npcId) .. ' stopped following')
end

local function handleNpcAttack(msg)
    local data = msg.data or {}
    local npcId = data.npcId
    local targetId = data.targetCharacterId

    if not npcId or not targetId then
        print('[ZDORPG] NpcAttack: missing npcId or targetCharacterId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] NpcAttack: NPC not found: ' .. tostring(npcId))
        return
    end

    local target = activeNpcs[targetId]
    if not target then
        if playerObject and playerObject.recordId == targetId then
            target = playerObject
        else
            print('[ZDORPG] NpcAttack: target not found: ' .. tostring(targetId))
            return
        end
    end

    local ok, err = pcall(function()
        npc:sendEvent('RemoveAIPackages', 'Combat')
        npc:sendEvent('StartAIPackage', {type = 'Combat', target = target})
    end)
    if not ok then
        print('[ZDORPG] NpcAttack: failed: ' .. tostring(err))
        return
    end

    print('[ZDORPG] NPC ' .. tostring(npcId) .. ' attacking ' .. tostring(targetId))
end

local function handleNpcStopAttack(msg)
    local data = msg.data or {}
    local npcId = data.npcId

    if not npcId then
        print('[ZDORPG] NpcStopAttack: missing npcId')
        return
    end

    local npc = activeNpcs[npcId]
    if not npc then
        print('[ZDORPG] NpcStopAttack: NPC not found: ' .. tostring(npcId))
        return
    end

    local ok, err = pcall(function()
        npc:sendEvent('RemoveAIPackages', 'Combat')
    end)
    if not ok then
        print('[ZDORPG] NpcStopAttack: failed: ' .. tostring(err))
        return
    end

    print('[ZDORPG] NPC ' .. tostring(npcId) .. ' stopped attacking')
end

local function handleNpcSpeaks(msg)
    if not playerObject then return end
    local data = msg.data or {}
    local npcName = data.npcId or '???'
    if data.npcId then
        local npc = activeNpcs[data.npcId]
        if npc then
            local okRec, record = pcall(types.NPC.record, npc)
            if okRec and record then
                npcName = record.name
            end
        end
    end
    playerObject:sendEvent('ZdorpgShowSpeech', {
        npcName = npcName,
        text = data.text or '',
        animate = true,
    })
end

local function handleShowMessageBox(msg)
    if not playerObject then return end
    local data = msg.data or {}
    playerObject:sendEvent('ZdorpgNotify', { text = data.message or '' })
end

-------------------------------------------------------------------------------
-- Message dispatch
-------------------------------------------------------------------------------

local function processIncomingMessage(msg)
    print('[ZDORPG:DEBUG] Processing message: ' .. tostring(msg.type))

    if msg.type == 'GetPlayerInfo' then
        handleGetPlayerInfo(msg)
    elseif msg.type == 'GetNpcInfo' then
        handleGetNpcInfo(msg)
    elseif msg.type == 'SayMp3File' then
        handleSayMp3File(msg)
    elseif msg.type == 'SpeechRecognitionInProgress' then
        handleSpeechRecognitionInProgress(msg)
    elseif msg.type == 'SpeechRecognitionComplete' then
        handleSpeechRecognitionComplete(msg)
    elseif msg.type == 'PlayerStartSpeak' then
        handlePlayerStartSpeak(msg)
    elseif msg.type == 'PlayerStopSpeak' then
        handlePlayerStopSpeak(msg)
    elseif msg.type == 'NpcSpeaks' then
        handleNpcSpeaks(msg)
    elseif msg.type == 'GetCharactersWhoHear' then
        handleGetCharactersWhoHear(msg)
    elseif msg.type == 'SpawnOnGroundInFrontOfCharacter' then
        handleSpawnOnGroundInFrontOfCharacter(msg)
    elseif msg.type == 'PlaySound3dOnCharacter' then
        handlePlaySound3dOnCharacter(msg)
    elseif msg.type == 'NpcStartFollowCharacter' then
        handleNpcStartFollowCharacter(msg)
    elseif msg.type == 'NpcStopFollowCharacter' then
        handleNpcStopFollowCharacter(msg)
    elseif msg.type == 'NpcAttack' then
        handleNpcAttack(msg)
    elseif msg.type == 'NpcStopAttack' then
        handleNpcStopAttack(msg)
    elseif msg.type == 'StartSession' then
        handleStartSession(msg)
    elseif msg.type == 'ShowMessageBox' then
        handleShowMessageBox(msg)
    else
        print('[ZDORPG:ERROR] Unknown message type: ' .. tostring(msg.type))
    end
end

-------------------------------------------------------------------------------
-- Cell change detection
-------------------------------------------------------------------------------

local function checkCellChange()
    if not playerObject then return end
    local ok, cell = pcall(function() return playerObject.cell end)
    if not ok or not cell then return end
    local cellName = cell.name or cell.id
    if cellName ~= lastCellName then
        lastCellName = cellName
        publish('CellChange', {
            playerId = playerObject.recordId,
            cellName = cellName,
        })
    end
end

-------------------------------------------------------------------------------
-- Engine handlers
-------------------------------------------------------------------------------

local function onUpdate(dt)
    frameCounter = frameCounter + 1
    if frameCounter % POLL_INTERVAL_FRAMES ~= 0 then return end

    local messages, newLastId = ipc.readIncoming(vfs, lastSeenClientMsgId)
    if messages then
        lastSeenClientMsgId = newLastId
        for _, msg in ipairs(messages) do
            local ok, err = pcall(processIncomingMessage, msg)
            if not ok then
                print('[ZDORPG] Error processing message: ' .. tostring(err))
            end
        end
        ipc.sendAck(lastSeenClientMsgId)
    end

    checkCellChange()
end

local function onPlayerAdded(player)
    playerObject = player
    print('[ZDORPG] Player added: ' .. tostring(player.recordId))
    publish('PlayerAdded', {
        playerId = player.recordId,
    })
    if clientConnected then
        showConnectedIndicator()
    end
end

local function onActorActive(actor)
    if types.NPC.objectIsInstance(actor) then
        activeNpcs[actor.recordId] = actor
    end
end

local function onObjectActive(object)
end

-------------------------------------------------------------------------------
-- Event handlers (from player script)
-------------------------------------------------------------------------------

local function onTargetChanged(data)
    publish('TargetChanged', {
        playerId = data.playerId,
        npcId = data.npcId,
    })
end

local function onPlayerSpeaks(data)
    publish('PlayerSpeaksText', {
        playerId = data.playerId,
        text = data.text,
        targetCharacterId = data.targetNpcId,
        gameTime = '0',
    })
end

-------------------------------------------------------------------------------
-- Save / Load
-------------------------------------------------------------------------------

local function onSave()
    return {
        lastSeenClientMsgId = lastSeenClientMsgId,
        lastCellName = lastCellName,
        modMsgCounter = modMsgCounter,
    }
end

local function rebuildActiveNpcs()
    activeNpcs = {}
    for _, actor in ipairs(world.activeActors) do
        if types.NPC.objectIsInstance(actor) then
            activeNpcs[actor.recordId] = actor
        end
    end
    print('[ZDORPG] Rebuilt activeNpcs: ' .. tostring(#world.activeActors) .. ' actors checked')
end

local function onLoad(data)
    if data then
        lastSeenClientMsgId = data.lastSeenClientMsgId or -1
        lastCellName = data.lastCellName
        modMsgCounter = data.modMsgCounter or 0
    end
    rebuildActiveNpcs()
    -- Try to restore playerObject (onPlayerAdded may not fire after reloadlua)
    for _, actor in ipairs(world.activeActors) do
        if types.Player.objectIsInstance(actor) then
            playerObject = actor
            break
        end
    end
    publish('GameSaveLoad', {})
end

-------------------------------------------------------------------------------
-- Script interface
-------------------------------------------------------------------------------

print('[ZDORPG] Global script loaded')

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
        onPlayerAdded = onPlayerAdded,
        onActorActive = onActorActive,
        onObjectActive = onObjectActive,
    },
    eventHandlers = {
        ZdorpgTargetChanged = onTargetChanged,
        ZdorpgPlayerSpeaks = onPlayerSpeaks,
    },
}
