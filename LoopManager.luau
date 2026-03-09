local RunService = game:GetService("RunService")

export type LoopMode = "render" | "heart" | "step"
export type LoopOptions = {
	mode: LoopMode?,
	delay: number?,
	maxErrors: number?,
	onError: ((id: string, err: string) -> ())?,
	priority: number?,
}
export type LoopEntry = {
	connection: RBXScriptConnection,
	createdAt: number,
	errorCount: number,
	totalCalls: number,
	totalTime: number,
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

local _active: { [string]: LoopEntry } = {}

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
	warn(`[LoopManager] '{id}': RenderStepped does not exist on the server. Using Heartbeat.`)
		options.mode = "heart"
	end

	if _active[id] then LoopManager.stop(id) end

	local signal  = SIGNALS[options.mode] or SIGNALS.heart
	local delay   = options.delay or 0
	local elapsed = 0
	local entry: LoopEntry = {
		connection = nil :: any,
		createdAt  = os.clock(),
		errorCount = 0,
		totalCalls = 0,
		totalTime  = 0,
	}

	entry.connection = signal:Connect(function(dt: number)
		if delay > 0 then
			elapsed += dt
			if elapsed < delay then return end
			dt, elapsed = elapsed, 0
		end

		entry.totalCalls += 1
		local t0 = os.clock()

		local ok, err = pcall(fn, dt)

		entry.totalTime += os.clock() - t0

		if not ok then
			entry.errorCount += 1
			local msg = `[LoopManager '{id}'] erro #{entry.errorCount}: {err}`

			if options.onError then
				options.onError(id, err)
			else
				warn(msg)
			end

		-- Auto-kill reaches limit of consecutive errors
			if options.maxErrors and entry.errorCount >= options.maxErrors then
				warn(`[LoopManager '{id}'] desativado após {entry.errorCount} erros.`)
				LoopManager.stop(id)
			end
		end
	end)

	_active[id] = entry
end

function LoopManager.stop(id: string)
	local entry = _active[id]
	if entry then
		entry.connection:Disconnect()
		_active[id] = nil
	end
end

function LoopManager.stopAll()
	for id in table.clone(_active) do
		LoopManager.stop(id)
	end
end

function LoopManager.stats(id: string)
	local entry = _active[id]
	if not entry then return nil end
	local avgMs = entry.totalCalls > 0
		and (entry.totalTime / entry.totalCalls) * 1000
		or  0
	return {
		id         = id,
		uptime     = os.clock() - entry.createdAt,
		totalCalls = entry.totalCalls,
		errorCount = entry.errorCount,
		avgMs      = avgMs,
	}
end

function LoopManager.list(): { string }
	local ids = {}
	for id in _active do table.insert(ids, id) end
	table.sort(ids) 
	return ids
end

function LoopManager.isRunning(id: string): boolean
	return _active[id] ~= nil
end

return LoopManager
