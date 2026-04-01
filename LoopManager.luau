--[[
		LoopManager.start("id", function(dt) ... end, {
			mode = "heart",      -- "render", "heart", "step"
			delay = 0.5,         
			priority = 1,        
			maxErrors = 5,       
			onError = function(id, err) warn(id, err) end
		})
		LoopManager.pause("id")
		LoopManager.resume("id")
		LoopManager.setDelay("id", 1.0)
		LoopManager.health()   
]]

local RunService = game:GetService("RunService")

export type LoopMode = "render" | "heart" | "step"
export type LoopOptions = {
	mode: LoopMode?,
	delay: number?,
	maxErrors: number?,
	onError: ((id: string, err: string) -> ())?,
	priority: number?,
	enabled: boolean?,        
}

type TaskEntry = {
	id: string,
	fn: (dt: number) -> (),
	mode: LoopMode,
	delay: number,
	elapsed: number,
	maxErrors: number,
	onError: ((id: string, err: string) -> ())?,
	priority: number,
	createdAt: number,
	errorCount: number,
	totalCalls: number,
	totalTime: number,
	maxDurationMs: number,      
	lastError: string?,
	lastErrorTime: number?,
	dead: boolean,
	paused: boolean,
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
	enabled   = true,
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

-- Flat lookup: id -> task
local _index: { [string]: TaskEntry } = {}

-- Dirty flag: re-sort before next dispatch if priority changed
local _dirty: { [LoopMode]: boolean } = { render = false, heart = false, step = false }

local function sortTasks(mode: LoopMode)
	table.sort(_tasks[mode], function(a, b)
		return a.priority > b.priority
	end)
	_dirty[mode] = false
end

local function validateNumber(value: any, name: string, min: number?, max: number?): number
	local num = tonumber(value)
	if num == nil then error(`{name} must be a number`, 2) end
	if num ~= num then error(`{name} cannot be NaN`, 2) end
	if num == math.huge or num == -math.huge then error(`{name} cannot be infinite`, 2) end
	if min and num < min then error(`{name} must be >= {min}`, 2) end
	if max and num > max then error(`{name} must be <= {max}`, 2) end
	return num
end

local function validateId(id: any): string
	if type(id) ~= "string" then error("id must be a string", 2) end
	if #id == 0 then error("id cannot be empty", 2) end
	if #id > 50 then error("id too long (max 50)", 2) end
	if not id:match("^[%w_:%-]+$") then
		error("id contains invalid characters (only alphanumeric, _, :, -)", 2)
	end
	return id
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

local function ensureDispatcher(mode: LoopMode)
	if not _dispatchers[mode] then
		_dispatchers[mode] = SIGNALS[mode]:Connect(function(dt: number)
			local list = _tasks[mode]
			if #list == 0 then return end
			if _dirty[mode] then sortTasks(mode) end

			local i = 1
			while i <= #list do
				local task = list[i]
				if task.paused then
					i += 1
					continue
				end

				-- Throttle by delay
				local execDt = dt
				if task.delay > 0 then
					task.elapsed += dt
					if task.elapsed < task.delay then
						i += 1
						continue
					end
					execDt = task.elapsed
					task.elapsed = 0
				end

				task.totalCalls += 1
				local t0 = os.clock()
				local ok, err = pcall(task.fn, execDt)
				local durationMs = (os.clock() - t0) * 1000
				task.totalTime += durationMs / 1000 -- em segundos
				if durationMs > task.maxDurationMs then
					task.maxDurationMs = durationMs
				end

				if not ok then
					task.errorCount += 1
					task.lastError = tostring(err)
					task.lastErrorTime = os.clock()

					if task.onError then
						task.onError(task.id, task.lastError)
					else
						warn(`[LoopManager] error in task "{task.id}": {task.lastError}`)
					end

					if task.errorCount >= task.maxErrors then
						warn(`[LoopManager] task "{task.id}" disabled after {task.errorCount} errors.`)
						task.dead = true
					end
				end

				if task.dead then
					table.remove(list, i)
					-- i stays the same (next element shifted)
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
end

function LoopManager.start(id: string, fn: (dt: number) -> (), opts: LoopOptions?)
	id = validateId(id)
	assert(type(fn) == "function", "fn must be a function")

	local options = mergeOptions(opts)
	options.mode = options.mode or "heart"
	if IS_SERVER and options.mode == "render" then
		warn(`[LoopManager] '{id}': RenderStepped is client-only. Using Heartbeat.`)
		options.mode = "heart"
	end

	-- Validate numeric fields
	options.delay = validateNumber(options.delay, "delay", 0)
	options.priority = validateNumber(options.priority, "priority")
	options.maxErrors = math.floor(validateNumber(options.maxErrors, "maxErrors", 1))

	-- Replace existing task
	if _index[id] then LoopManager.stop(id) end

	local mode = options.mode :: LoopMode
	local task: TaskEntry = {
		id         = id,
		fn         = fn,
		mode       = mode,
		delay      = options.delay,
		elapsed    = 0,
		maxErrors  = options.maxErrors,
		onError    = options.onError,
		priority   = options.priority,
		createdAt  = os.clock(),
		errorCount = 0,
		totalCalls = 0,
		totalTime  = 0,
		maxDurationMs = 0,
		lastError  = nil,
		lastErrorTime = nil,
		dead       = false,
		paused     = not options.enabled, 
	}

	table.insert(_tasks[mode], task)
	_dirty[mode] = true
	_index[id] = task

	ensureDispatcher(mode)
end

function LoopManager.stop(id: string)
	local task = _index[id]
	if not task then return end
	task.dead = true
	_index[id] = nil
end

function LoopManager.stopAll()
	for id, _ in pairs(table.clone(_index)) do
		LoopManager.stop(id)
	end
end

function LoopManager.pause(id: string)
	local task = _index[id]
	if task then task.paused = true end
end

function LoopManager.resume(id: string)
	local task = _index[id]
	if task then task.paused = false end
end

function LoopManager.isRunning(id: string): boolean
	local task = _index[id]
	return task ~= nil and not task.dead
end

function LoopManager.isPaused(id: string): boolean
	local task = _index[id]
	return task ~= nil and task.paused
end

function LoopManager.setPriority(id: string, priority: number)
	priority = validateNumber(priority, "priority")
	local task = _index[id]
	if not task then return end
	task.priority = priority
	_dirty[task.mode] = true
end

function LoopManager.setDelay(id: string, delay: number)
	delay = validateNumber(delay, "delay", 0)
	local task = _index[id]
	if task then task.delay = delay end
end

function LoopManager.setMaxErrors(id: string, maxErrors: number)
	maxErrors = math.floor(validateNumber(maxErrors, "maxErrors", 1))
	local task = _index[id]
	if task then task.maxErrors = maxErrors end
end

function LoopManager.setOnError(id: string, onError: ((id: string, err: string) -> ())?)
	local task = _index[id]
	if task then task.onError = onError end
end

function LoopManager.stats(id: string)
	local task = _index[id]
	if not task then return nil end
	local avgMs = task.totalCalls > 0 and (task.totalTime / task.totalCalls) * 1000 or 0
	return {
		id          = task.id,
		mode        = task.mode,
		uptime      = os.clock() - task.createdAt,
		totalCalls  = task.totalCalls,
		errorCount  = task.errorCount,
		avgMs       = avgMs,
		maxDurationMs = task.maxDurationMs,
		lastError   = task.lastError,
		lastErrorTime = task.lastErrorTime,
		paused      = task.paused,
	}
end

function LoopManager.list(): { string }
	local ids = {}
	for id in pairs(_index) do table.insert(ids, id) end
	table.sort(ids)
	return ids
end

function LoopManager.health()
	local totalTasks = 0
	local running = 0
	local paused = 0
	local totalCalls = 0
	local totalErrors = 0
	local longestRun = 0
	local oldestTask = math.huge

	for _, task in pairs(_index) do
		if not task.dead then
			totalTasks += 1
			if task.paused then paused += 1 else running += 1 end
			totalCalls += task.totalCalls
			totalErrors += task.errorCount
			if task.maxDurationMs > longestRun then longestRun = task.maxDurationMs end
			if task.createdAt < oldestTask then oldestTask = task.createdAt end
		end
	end

	return {
		totalTasks = totalTasks,
		running = running,
		paused = paused,
		totalCalls = totalCalls,
		totalErrors = totalErrors,
		longestRunMs = longestRun,
		uptimeTotal = oldestTask ~= math.huge and os.clock() - oldestTask or 0,
	}
end

return LoopManager
