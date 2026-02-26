-- ZDORPG Player Script
-- Handles raycasting for NPC target detection, voice playback, HUD speech

local async = require('openmw.async')
local camera = require('openmw.camera')
local core = require('openmw.core')
local input = require('openmw.input')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local storage = require('openmw.storage')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local L = core.l10n('zdorpgai')

-------------------------------------------------------------------------------
-- Settings & input trigger registration
-------------------------------------------------------------------------------

input.registerTrigger {
    key = 'ZdorpgOpenChat',
    l10n = 'zdorpgai',
    name = 'trigger_open_chat',
    description = 'trigger_open_chat_desc',
}

I.Settings.registerPage {
    key = 'ZdorpgSettings',
    l10n = 'zdorpgai',
    name = 'settings_page_name',
    description = 'settings_page_desc',
}

I.Settings.registerGroup {
    key = 'SettingsZdorpgPlayer',
    page = 'ZdorpgSettings',
    l10n = 'zdorpgai',
    name = 'settings_chat_group',
    permanentStorage = true,
    settings = {
        {
            key = 'textChatEnabled',
            default = false,
            renderer = 'checkbox',
            name = 'settings_chat_enabled',
            description = 'settings_chat_enabled_desc',
        },
        {
            key = 'textChatKey',
            default = 'Y',
            renderer = 'inputBinding',
            name = 'settings_chat_key',
            description = 'settings_chat_key_desc',
            argument = {
                key = 'ZdorpgOpenChat',
                type = 'trigger',
            },
        },
    },
}

local playerSettings = storage.playerSection('SettingsZdorpgPlayer')

-- State
local TARGET_CHECK_FRAMES = 10
local frameCounter = 0
local lastTargetId = nil
local speechHideTime = nil
local listeningHideTime = nil

-- Typewriter animation state
local DEFAULT_CHARS_PER_SEC = 18
local speechAnimPrefix = nil
local speechAnimText = nil
local speechAnimCharOffsets = nil  -- byte offset of end of each UTF-8 char
local speechAnimStart = nil
local speechAnimRevealed = 0
local speechAnimCharsPerSec = DEFAULT_CHARS_PER_SEC
local speechAnimHoldDuration = nil  -- how long text stays after fully revealed

-- Chat text input state (press Y to type instead of mic)
local chatActive = false
local chatText = ''
local chatElement = nil
local chatHintElement = nil

-- Shift key mapping for US keyboard layout (symbol keys)
local SHIFT_MAP = {
    ['1'] = '!', ['2'] = '@', ['3'] = '#', ['4'] = '$', ['5'] = '%',
    ['6'] = '^', ['7'] = '&', ['8'] = '*', ['9'] = '(', ['0'] = ')',
    ['-'] = '_', ['='] = '+', ['['] = '{', [']'] = '}', ['\\'] = '|',
    [';'] = ':', ["'"] = '"', [','] = '<', ['.'] = '>', ['/'] = '?',
    ['`'] = '~',
}

--- Build table of byte offsets marking the end of each UTF-8 character.
local function utf8CharOffsets(s)
    local offsets = {}
    local i = 1
    while i <= #s do
        local b = string.byte(s, i)
        local charLen
        if b < 0x80 then charLen = 1
        elseif b < 0xE0 then charLen = 2
        elseif b < 0xF0 then charLen = 3
        else charLen = 4 end
        i = i + charLen
        offsets[#offsets + 1] = i - 1
    end
    return offsets
end

-------------------------------------------------------------------------------
-- Target detection (raycast)
-------------------------------------------------------------------------------

local function checkTarget()
    local ok, pos = pcall(camera.getPosition)
    if not ok or not pos then return end

    local okDir, viewTransform = pcall(camera.getViewTransform)
    if not okDir or not viewTransform then return end

    local invView = viewTransform:inverse()
    local forward = invView:apply(util.vector3(0, 0, -1))
    local dir = (forward - pos):normalize()
    local to = pos + dir * 2000

    local okRay, result = pcall(nearby.castRenderingRay, pos, to)
    if not okRay then return end

    local targetId = nil
    if result and result.hitObject and result.hitObject ~= self.object then
        local okCheck, isNpc = pcall(types.NPC.objectIsInstance, result.hitObject)
        if okCheck and isNpc then
            targetId = result.hitObject.recordId
        end
    end

    if targetId ~= lastTargetId then
        lastTargetId = targetId
        print('[ZDORPG_DEBUG] Target changed: ' .. tostring(targetId))
        core.sendGlobalEvent('ZdorpgTargetChanged', {
            playerId = self.object.recordId,
            npcId = targetId,
        })
    end
end

-------------------------------------------------------------------------------
-- UI elements — destroyed and recreated on every text change for robustness
-------------------------------------------------------------------------------

local speechElement = nil
local listeningElement = nil

local SPEECH_PADDING = 80

local function destroyElements()
    if speechElement then
        speechElement:destroy()
        speechElement = nil
    end
    if listeningElement then
        listeningElement:destroy()
        listeningElement = nil
    end
    if chatElement then
        chatElement:destroy()
        chatElement = nil
    end
    if chatHintElement then
        chatHintElement:destroy()
        chatHintElement = nil
    end
end

local function setSpeechText(text)
    if speechElement then
        speechElement:destroy()
    end
    local screenWidth = ui.screenSize().x
    local maxWidth = screenWidth - SPEECH_PADDING * 2
    speechElement = ui.create {
        layer = 'HUD',
        type = ui.TYPE.Text,
        props = {
            relativePosition = util.vector2(0.5, 1),
            anchor = util.vector2(0.5, 1),
            position = util.vector2(0, -80),
            -- size = util.vector2(maxWidth, 300),
            size = util.vector2(800, 300),
            autoSize = false,
            text = text,
            textSize = 16,
            textColor = util.color.rgb(0.871, 0.867, 0.667),
            wordWrap = true,
            textAlignH = ui.ALIGNMENT.Center,
            textAlignV = ui.ALIGNMENT.End,
        },
    }
end

local function setListeningText(text)
    if listeningElement then
        listeningElement:destroy()
    end
    local screenWidth = ui.screenSize().x
    listeningElement = ui.create {
        layer = 'HUD',
        type = ui.TYPE.Text,
        props = {
            relativePosition = util.vector2(1, 1),
            anchor = util.vector2(1, 1),
            position = util.vector2(-20, -200),
            -- size = util.vector2(screenWidth * 0.3, 300),
            size = util.vector2(800, 300),
            autoSize = false,
            text = text,
            textSize = 16,
            textColor = util.color.rgb(0.871, 0.867, 0.667),
            wordWrap = true,
            textAlignH = ui.ALIGNMENT.End,
            textAlignV = ui.ALIGNMENT.End,
        },
    }
end

-------------------------------------------------------------------------------
-- Speech bubble
-------------------------------------------------------------------------------

local function stopSpeechAnim()
    speechAnimPrefix = nil
    speechAnimText = nil
    speechAnimCharOffsets = nil
    speechAnimStart = nil
    speechAnimRevealed = 0
    speechAnimCharsPerSec = DEFAULT_CHARS_PER_SEC
    speechAnimHoldDuration = nil
end

local function showSpeech(npcName, text, animate, duration)
    stopSpeechAnim()
    speechHideTime = nil

    local prefix = npcName .. ': '

    if not duration then
        duration = math.max(2, #(prefix .. text) / 30)
    end

    if animate then
        speechAnimPrefix = prefix
        speechAnimText = text
        speechAnimCharOffsets = utf8CharOffsets(text)
        speechAnimStart = core.getRealTime()
        speechAnimRevealed = 0

        local numChars = #speechAnimCharOffsets
        if numChars > 0 and duration > 0 then
            -- Reveal all characters over the full audio duration, then hold 3s extra
            speechAnimCharsPerSec = numChars / duration
            speechAnimHoldDuration = 3
        else
            speechAnimCharsPerSec = DEFAULT_CHARS_PER_SEC
            speechAnimHoldDuration = 3
        end

        setSpeechText(prefix)
    else
        setSpeechText(prefix .. text)
        speechHideTime = core.getRealTime() + duration
    end
end

local function hideSpeech()
    stopSpeechAnim()
    speechHideTime = nil
    setSpeechText('')
end

-------------------------------------------------------------------------------
-- Listening indicator
-------------------------------------------------------------------------------

local function showListening(text)
    setListeningText(text or L('listening'))
    listeningHideTime = core.getRealTime() + 4
end

local function hideListening()
    listeningHideTime = nil
    setListeningText('')
end

-------------------------------------------------------------------------------
-- Chat text input (no-mic mode, press Y to open)
-------------------------------------------------------------------------------

local function updateChatUI()
    if chatElement then chatElement:destroy() end
    if not chatActive then
        chatElement = nil
        return
    end
    chatElement = ui.create {
        layer = 'HUD',
        type = ui.TYPE.Text,
        props = {
            relativePosition = util.vector2(0.5, 1),
            anchor = util.vector2(0.5, 1),
            position = util.vector2(0, -40),
            size = util.vector2(800, 24),
            autoSize = false,
            text = 'Say: ' .. chatText .. '_',
            textSize = 16,
            textColor = util.color.rgb(0.871, 0.867, 0.667),
            textAlignH = ui.ALIGNMENT.Center,
            textAlignV = ui.ALIGNMENT.End,
        },
    }
end

local function showChatHint()
    if chatHintElement then chatHintElement:destroy() end
    chatHintElement = ui.create {
        layer = 'HUD',
        type = ui.TYPE.Text,
        props = {
            relativePosition = util.vector2(0.5, 1),
            anchor = util.vector2(0.5, 1),
            position = util.vector2(0, -12),
            size = util.vector2(800, 18),
            autoSize = false,
            text = 'Enter to send, Esc to cancel',
            textSize = 14,
            textColor = util.color.rgb(0.6, 0.6, 0.4),
            textAlignH = ui.ALIGNMENT.Center,
            textAlignV = ui.ALIGNMENT.End,
        },
    }
end

local function hideChatHint()
    if chatHintElement then
        chatHintElement:destroy()
        chatHintElement = nil
    end
end

local function setGameControls(enabled)
    input.setControlSwitch(input.CONTROL_SWITCH.Controls, enabled)
    input.setControlSwitch(input.CONTROL_SWITCH.Fighting, enabled)
    input.setControlSwitch(input.CONTROL_SWITCH.Jumping, enabled)
    input.setControlSwitch(input.CONTROL_SWITCH.Looking, enabled)
    input.setControlSwitch(input.CONTROL_SWITCH.Magic, enabled)
    input.setControlSwitch(input.CONTROL_SWITCH.ViewMode, enabled)
    input.setControlSwitch(input.CONTROL_SWITCH.VanityMode, enabled)
end

local function openChatInput()
    if chatActive then return end
    chatActive = true
    chatText = ''
    setGameControls(false)
    showChatHint()
    updateChatUI()
end

-- Trigger handler: fired when the user presses the bound chat key
input.registerTriggerHandler('ZdorpgOpenChat', async:callback(function()
    if playerSettings:get('textChatEnabled') then
        openChatInput()
    end
end))

local function closeChatInput()
    chatActive = false
    chatText = ''
    setGameControls(true)
    hideChatHint()
    updateChatUI()
end

local function submitChatInput()
    if chatText ~= '' then
        core.sendGlobalEvent('ZdorpgPlayerSpeaks', {
            playerId = self.object.recordId,
            text = chatText,
            targetNpcId = lastTargetId,
        })
    end
    closeChatInput()
end

--- Remove the last UTF-8 character from a string.
local function utf8RemoveLast(s)
    if #s == 0 then return '' end
    local i = #s
    while i > 0 and string.byte(s, i) >= 0x80 and string.byte(s, i) < 0xC0 do
        i = i - 1
    end
    return s:sub(1, i - 1)
end

local function onKeyPress(key)
    if not chatActive then return end
    if key.code == input.KEY.Enter or key.code == input.KEY.NP_Enter then
        submitChatInput()
    elseif key.code == input.KEY.Escape then
        closeChatInput()
    elseif key.code == input.KEY.Backspace then
        chatText = utf8RemoveLast(chatText)
        updateChatUI()
    elseif key.symbol and key.symbol ~= '' then
        local ch = key.symbol
        if key.withShift and #ch == 1 then
            if ch:match('[a-z]') then
                ch = ch:upper()
            elseif SHIFT_MAP[ch] then
                ch = SHIFT_MAP[ch]
            end
        end
        chatText = chatText .. ch
        updateChatUI()
    end
end

-------------------------------------------------------------------------------
-- Engine handlers
-------------------------------------------------------------------------------

local function onFrame(dt)
    -- Typewriter animation (UTF-8 aware)
    if speechAnimText then
        local numChars = #speechAnimCharOffsets
        local elapsed = core.getRealTime() - speechAnimStart
        local target = math.min(math.floor(elapsed * speechAnimCharsPerSec) + 1, numChars)
        if target ~= speechAnimRevealed then
            speechAnimRevealed = target
            local byteEnd = speechAnimCharOffsets[target]
            setSpeechText(speechAnimPrefix .. string.sub(speechAnimText, 1, byteEnd))
        end
        if target >= numChars then
            speechHideTime = core.getRealTime() + speechAnimHoldDuration
            stopSpeechAnim()
        end
    end

    if speechHideTime and core.getRealTime() >= speechHideTime then
        hideSpeech()
    end

    if listeningHideTime and core.getRealTime() >= listeningHideTime then
        hideListening()
    end

    frameCounter = frameCounter + 1
    if frameCounter % TARGET_CHECK_FRAMES ~= 0 then return end
    pcall(checkTarget)
end

-------------------------------------------------------------------------------
-- Event handlers (from global script)
-------------------------------------------------------------------------------

local function onSayMp3(data)
    local npc = data.npc
    if npc then
        local okSay, err = pcall(function()
            core.sound.say('zdorpgai_mp3/' .. data.mp3Name, npc, data.text or '')
        end)
        if not okSay then
            print('[ZDORPG] Error playing voice: ' .. tostring(err))
        end
    else
        print('[ZDORPG] NPC object not provided for voice')
    end
end

local function onShowSpeech(data)
    local duration = data.durationSec or (data.persistent and 9999 or nil)
    showSpeech(data.npcName or '???', data.text or '', data.animate, duration)
end

local function onHideSpeech(data)
    hideSpeech()
end

local function onShowListening(data)
    showListening(data.text)
end

local function onHideListening(data)
    hideListening()
end

local function onNotify(data)
    ui.showMessage(data.text or '')
end

-------------------------------------------------------------------------------
-- Save / Load
-------------------------------------------------------------------------------

local function onSave()
    if chatActive then closeChatInput() end
    destroyElements()
    stopSpeechAnim()
    speechHideTime = nil
    listeningHideTime = nil
    return {
        lastTargetId = lastTargetId,
    }
end

local function onLoad(data)
    if data then
        lastTargetId = data.lastTargetId
    end
    chatActive = false
    chatText = ''
    destroyElements()
    stopSpeechAnim()
    speechHideTime = nil
    listeningHideTime = nil
end

-------------------------------------------------------------------------------
-- Script interface
-------------------------------------------------------------------------------

print('[ZDORPG] Player script loaded')

return {
    engineHandlers = {
        onFrame = onFrame,
        onKeyPress = onKeyPress,
        onSave = onSave,
        onLoad = onLoad,
    },
    eventHandlers = {
        ZdorpgSayMp3 = onSayMp3,
        ZdorpgShowSpeech = onShowSpeech,
        ZdorpgHideSpeech = onHideSpeech,
        ZdorpgShowListening = onShowListening,
        ZdorpgHideListening = onHideListening,
        ZdorpgNotify = onNotify,
    },
}
