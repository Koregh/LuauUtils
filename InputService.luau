--[[ How to use

    -- Bind action to keys
    InputService.bind("Shoot", { Enum.KeyCode.E, Enum.UserInputType.MouseButton1 })
    InputService.bind("Aim",   { Enum.UserInputType.MouseButton2 }, { toggle = true })

    -- Listen to action events
    InputService.onAction("Shoot", {
        began = function() print("Shoot started") end,
        ended = function() print("Shoot ended")   end,
    })

    -- Query state
    InputService.isDown("Shoot")    --> boolean
    InputService.isToggled("Aim")   --> boolean (only meaningful for toggle actions)

    -- Unbind
    InputService.unbind("Shoot")
]]

local UserInputService = game:GetService("UserInputService")

type Key = Enum.KeyCode | Enum.UserInputType

export type BindOptions = {
	toggle: boolean?,
}

export type ActionCallbacks = {
	began: (() -> ())?,
	ended: (() -> ())?,
}

type ActionState = {
	keys:         { Key },
	began:        (() -> ())?,
	ended:        (() -> ())?,
	isDown:       boolean,
	isToggle:     boolean,
	toggleActive: boolean,
}

local _actions:     { [string]: ActionState }  = {}
local _keyToAction: { [Key]:    string       } = {}

local function resolveKey(input: InputObject): string?
	return _keyToAction[input.KeyCode] or _keyToAction[input.UserInputType]
end

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then return end

	local name = resolveKey(input)
	if not name then return end

	local action = _actions[name]
	action.isDown = true

	if action.isToggle then
		action.toggleActive = not action.toggleActive
	end

	if action.began then action.began() end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	local name = resolveKey(input)
	if not name then return end

	local action = _actions[name]
	action.isDown = false

	if action.ended then action.ended() end
end)

local InputService = {}

--- Register an action linked to one or more keys.
--- If the action already existed, it is cleared.
function InputService.bind(name: string, keys: { Key }, opts: BindOptions?)
	assert(type(name) == "string" and #name > 0, "[InputService] name must be a non-empty string")
	assert(type(keys) == "table"  and #keys > 0,  "[InputService] keys must be a non-empty array")

	-- Clean up old key mappings if rebinding
	if _actions[name] then
		InputService.unbind(name)
	end

	local action: ActionState = {
		keys         = keys,
		isDown       = false,
		isToggle     = opts and opts.toggle or false,
		toggleActive = false,
	}

	_actions[name] = action

	for _, key in keys do
		_keyToAction[key] = name
	end
end

--- Removes an action and its key mappings.
function InputService.unbind(name: string)
	local action = _actions[name]
	if not action then return end

	for _, key in action.keys do
		_keyToAction[key] = nil
	end

	_actions[name] = nil
end

--- Connects callbacks to action events.
function InputService.onAction(name: string, callbacks: ActionCallbacks)
	local action = _actions[name]
	assert(action, `[InputService] onAction: action '{name}' is not bound`)

	action.began = callbacks.began
	action.ended = callbacks.ended
end

function InputService.isDown(name: string): boolean
	local action = _actions[name]
	return action ~= nil and action.isDown
end

function InputService.isToggled(name: string): boolean
	local action = _actions[name]
	return action ~= nil and action.toggleActive
end

function InputService.list(): { string }
	local names = {}
	for name in _actions do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return InputService
