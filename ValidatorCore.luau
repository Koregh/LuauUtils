--!strict
local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()

export type ValidationResult<T> = { success: true, value: T } | { success: false, error: string }
export type Validator<T> = (value: any) -> (boolean, any) -- Retorna (sucesso, valor_ou_erro)

local Config = {
	MaxDepth = 5,
	MaxKeys = 100,
	MaxStringLength = 100,
}

local ValidatorCore = {}

local compiledSchemas = {}
setmetatable(compiledSchemas, { __mode = "k" }) 

local MetricsService = {
	validations = 0,
	errors = 0,
}

local function recordSuccess()
	MetricsService.validations += 1
end

local function recordError(msg: string): (boolean, string)
	MetricsService.errors += 1
	return false, msg
end

local Types = {}

function Types.string(maxLen: number?): Validator<string>
	local limit = maxLen or Config.MaxStringLength
	return function(v: any)
		if type(v) ~= "string" or v == "" then return recordError("invalid string") end
		if IS_SERVER and #v > limit then return recordError("string too long") end
		
		recordSuccess()
		return true, v
	end
end

function Types.number(min: number?, max: number?): Validator<number>
	return function(v: any)
		if type(v) ~= "number" then return recordError("invalid number") end
		if min and v < min then return recordError("number too small") end
		if max and v > max then return recordError("number too big") end
		
		recordSuccess()
		return true, v
	end
end

function Types.oneOf(...: Validator<any>): Validator<any>
	local validators = { ... }
	return function(v: any)
		for _, check in ipairs(validators) do
			local success, result = check(v)
			if success then
				return true, result
			end
		end
		return recordError("invalid type (oneOf failed all branches)")
	end
end

local function validateTable(t: {[any]: any}, schema: {[string]: Validator<any>}, depth: number, seen: {[any]: boolean}): (boolean, any)
	if seen[t] then return recordError("circular table") end
	if depth > Config.MaxDepth then return recordError("table too deep") end
	
	seen[t] = true
	local count = 0
	local resultTable = {}

	for k, v in pairs(t) do
		count += 1
		if IS_SERVER and count > Config.MaxKeys then return recordError("table too large") end

		local validator = schema[k]
		if not validator then return recordError("unexpected key: " .. tostring(k)) end

		local success, result = validator(v)
		if not success then return false, `schema error at [{k}]: {result}` end
		
		resultTable[k] = result
	end

	return true, resultTable
end

function Types.schema(schemaConfig: {[string]: Validator<any>}): Validator<any>
	if compiledSchemas[schemaConfig] then
		return compiledSchemas[schemaConfig]
	end

	local fn = function(data: any)
		if type(data) ~= "table" then return recordError("expected table") end
		local success, result = validateTable(data, schemaConfig, 1, {})
		
		if success then recordSuccess() end
		return success, result
	end

	compiledSchemas[schemaConfig] = fn
	return fn
end

ValidatorCore.Types = Types
ValidatorCore.Metrics = MetricsService

return ValidatorCore
