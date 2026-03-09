type CacheEntry = {
	expires: number,   -- os.clock() no momento de expiração
	duration: number,  -- duração total do cooldown
}

type ExecuteCallback = () -> ()
type BlockedCallback = (timeLeft: number) -> ()


local DebounceService = {}
DebounceService.__index = DebounceService


local _cache: { [string]: CacheEntry } = {}
local _lastCleanup: number = os.clock()

-- Intervalo de limpeza automática do cache (em segundos)
local CLEANUP_INTERVAL: number = 60

local function _autoCleanup(): ()
	local now = os.clock()
	if now - _lastCleanup < CLEANUP_INTERVAL then return end

	for id, entry in pairs(_cache) do
		if now >= entry.expires then
			_cache[id] = nil
		end
	end

	_lastCleanup = now
end
local function _validateArgs(id: string, duration: number): ()
	assert(type(id) == "string" and #id > 0,
		"[DebounceService] 'id' deve ser uma string não-vazia.")

	assert(type(duration) == "number" and duration > 0,
		("[DebounceService] 'duration' deve ser um número positivo. Recebido: %s"):format(tostring(duration)))
end

function DebounceService.canDo(
	id: string,
	duration: number,
	onExecute: ExecuteCallback?,
	onBlocked: BlockedCallback?
): boolean
	_validateArgs(id, duration)
	_autoCleanup()

	local now = os.clock()
	local entry = _cache[id]

	if entry and now < entry.expires then
		if onBlocked then
			onBlocked(entry.expires - now)
		end
		return false
	end

	_cache[id] = {
		expires  = now + duration,
		duration = duration,
	}

	if onExecute then
		onExecute()
	end

	return true
end

function DebounceService.getAlpha(id: string): number
	assert(type(id) == "string" and #id > 0,
		"[DebounceService] 'id' deve ser uma string não-vazia.")

	local entry = _cache[id]
	if not entry then return 0 end

	local timeLeft = entry.expires - os.clock()
	if timeLeft <= 0 then return 0 end

	-- timeLeft / duration: 1.0 quando recém registrado, decai até 0
	return math.clamp(timeLeft / entry.duration, 0, 1)
end

function DebounceService.getTimeLeft(id: string): number
	assert(type(id) == "string" and #id > 0,
		"[DebounceService] 'id' deve ser uma string não-vazia.")

	local entry = _cache[id]
	if not entry then return 0 end

	return math.max(0, entry.expires - os.clock())
end

function DebounceService.isBlocked(id: string): boolean
	assert(type(id) == "string" and #id > 0,
		"[DebounceService] 'id' deve ser uma string não-vazia.")

	local entry = _cache[id]
	-- Retorno explícito de boolean (não nil) para segurança de tipos
	return entry ~= nil and os.clock() < entry.expires
end

function DebounceService.reset(id: string?): ()
	if id == nil then
		-- Reset global: útil para testes ou respawn de servidor
		table.clear(_cache)
		return
	end

	assert(type(id) == "string" and #id > 0,
		"[DebounceService] 'id' deve ser uma string não-vazia ou nil.")

	_cache[id] = nil
end

function DebounceService.flush(): ()
	local now = os.clock()
	for id, entry in pairs(_cache) do
		if now >= entry.expires then
			_cache[id] = nil
		end
	end
	_lastCleanup = now
end



function DebounceService._debugSnapshot(): { [string]: { timeLeft: number, alpha: number } }
	local snapshot = {}
	local now = os.clock()

	for id, entry in pairs(_cache) do
		local timeLeft = entry.expires - now
		if timeLeft > 0 then
			snapshot[id] = {
				timeLeft = timeLeft,
				alpha    = math.clamp(timeLeft / entry.duration, 0, 1),
			}
		end
	end

	return snapshot
end


return DebounceService
