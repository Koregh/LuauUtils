--[[ How to use

LoopManager.start("UpdateUI", function(dt)
    print("Test")
end, {
    mode = "render",      -- Uses RenderStepped (Client only)
    delay = 0.5,         -- Runs only every half second
    maxErrors = 3,        -- If there is an error 3 times, the loop kills itself
    priority = 1,         -- Higher = runs first within the same mode
    onError = function(id, err)
        warn(`Loop {id} broke with error: {err}`)
    end
}) ]]

local RunService = game:GetService("RunService")

export type LoopMode = "render" | "heart" | "step"
export type LoopOptions = {
	mode: LoopMode?,
	delay: number?,
	maxErrors: number?,
	onError: ((id: string, err: string) -> ())?,
	priority: number?,
}

type TaskEntry = {
	fn:         (dt: number) -> (),
	mode:       LoopMode,
	delay:      number,
	elapsed:    number,
	maxErrors:  number,
	onError:    ((id: string, err: string) -> ())?,
	priority:   number,
	createdAt:  number,
	errorCount: number,
	totalCalls: number,
	totalTime:  number,
	dead:       boolean,
}

local SIGNALS = {
	render = RunService.RenderStepped,
	heart  = RunService.Heartbeat,
	step   = RunService.Stepped,
}

local DEFAULT_OPTIONS: LoopOptions = {
	mode      = "heart",
	delay     = 0,
	maxErrors = 5,
	onError   = nil,
	priority  = 0,
}

local IS_SERVER = RunService:IsServer()

local LoopManager = {}
LoopManager.__index = LoopManager

-- One connection per RunService signal
local _dispatchers: { [LoopMode]: RBXScriptConnection? } = {}

-- Tasks grouped by mode, stored as ordered array (sorted by priority desc)
local _tasks: { [LoopMode]: { TaskEntry } } = {
	render = {},
	heart  = {},
	step   = {},
}

-- Flat lookup: id -> { mode, index hint }
local _index: { [string]: { mode: LoopMode, task: TaskEntry } } = {}

-- Dirty flag: re-sort before next dispatch if priority changed
local _dirty: { [LoopMode]: boolean } = { render = false, heart = false, step = false }

local function sortTasks(mode: LoopMode)
	table.sort(_tasks[mode], function(a, b)
		return a.priority > b.priority
	end)
	_dirty[mode] = false
end

local function runDispatcher(mode: LoopMode)
	return SIGNALS[mode]:Connect(function(dt: number)
		local list = _tasks[mode]
		if #list == 0 then return end
		if _dirty[mode] then sortTasks(mode) end

		local i = 1
		while i <= #list do
			local task = list[i]

			-- Throttle by delay
			if task.delay > 0 then
				task.elapsed += dt
				if task.elapsed < task.delay then
					i += 1
					continue
				end
				-- Pass accumulated time as dt so callbacks get real elapsed
				dt = task.elapsed
				task.elapsed = 0
			end

			task.totalCalls += 1
			local t0 = os.clock()
			local ok, err = pcall(task.fn, dt)
			task.totalTime += os.clock() - t0

			if not ok then
				task.errorCount += 1

				if task.onError then
					task.onError(task.mode, err) -- id is the mode key here, fixed below
				else
					warn(`[LoopManager] error in task: {err}`)
				end

				if task.errorCount >= task.maxErrors then
					warn(`[LoopManager] task disabled after {task.errorCount} errors.`)
					task.dead = true
				end
			end

			if task.dead then
				table.remove(list, i)
				-- i stays the same (next element shifted into position)
			else
				i += 1
			end
		end

		-- Kill dispatcher when no tasks remain
		if #list == 0 and _dispatchers[mode] then
			_dispatchers[mode]:Disconnect()
			_dispatchers[mode] = nil
		end
	end)
end

local function ensureDispatcher(mode: LoopMode)
	if not _dispatchers[mode] then
		_dispatchers[mode] = runDispatcher(mode)
	end
end

local function mergeOptions(opts: LoopOptions?): LoopOptions
	local merged = table.clone(DEFAULT_OPTIONS)
	if opts then
		for k, v in opts do
			merged[k] = v
		end
	end
	return merged
end


function LoopManager.start(id: string, fn: (dt: number) -> (), opts: LoopOptions?)
	assert(type(id) == "string" and #id > 0, "[LoopManager] id must be a non-empty string")
	assert(type(fn) == "function",           "[LoopManager] fn must be a function")

	local options = mergeOptions(opts)

	if IS_SERVER and options.mode == "render" then
		warn(`[LoopManager] '{id}': RenderStepped is client-only. Using Heartbeat.`)
		options.mode = "heart"
	end

	-- Replace existing task with same id
	if _index[id] then LoopManager.stop(id) end

	local mode = options.mode :: LoopMode
	local task: TaskEntry = {
		fn         = fn,
		mode       = mode,
		delay      = options.delay or 0,
		elapsed    = 0,
		maxErrors  = options.maxErrors or 5,
		onError    = options.onError,
		priority   = options.priority or 0,
		createdAt  = os.clock(),
		errorCount = 0,
		totalCalls = 0,
		totalTime  = 0,
		dead       = false,
	}

	-- Fix onError so it receives the task id
	if options.onError then
		local userCb = options.onError
		task.onError = function(_, err) userCb(id, err) end
	end

	table.insert(_tasks[mode], task)
	_dirty[mode] = true
	_index[id] = { mode = mode, task = task }

	ensureDispatcher(mode)
end

function LoopManager.stop(id: string)
	local entry = _index[id]
	if not entry then return end

	-- Mark dead; dispatcher will remove it on next tick
	entry.task.dead = true
	_index[id] = nil
end

function LoopManager.stopAll()
	for id in table.clone(_index) do
		LoopManager.stop(id)
	end
end

function LoopManager.stats(id: string)
	local entry = _index[id]
	if not entry then return nil end
	local task = entry.task
	local avgMs = task.totalCalls > 0
		and (task.totalTime / task.totalCalls) * 1000
		or  0
	return {
		id         = id,
		mode       = task.mode,
		uptime     = os.clock() - task.createdAt,
		totalCalls = task.totalCalls,
		errorCount = task.errorCount,
		avgMs      = avgMs,
	}
end

function LoopManager.list(): { string }
	local ids = {}
	for id in _index do table.insert(ids, id) end
	table.sort(ids)
	return ids
end

function LoopManager.isRunning(id: string): boolean
	return _index[id] ~= nil
end

-- Change priority at runtime without restarting the task
function LoopManager.setPriority(id: string, priority: number)
	local entry = _index[id]
	if not entry then return end
	entry.task.priority = priority
	_dirty[entry.mode] = true
end

return LoopManager
