--!strict

local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()

export type Validator<T> = (value: any, context?: ValidationContext) -> (boolean, T | string)

export type ValidationContext = {
	path: string,              
	metrics: MetricsCollector,  
}

type MetricsCollector = {
	recordSuccess: () -> (),
	recordError: (msg: string) -> (),
}

type SchemaConfig = { [string]: Validator<any> }
type CompiledSchema = { validator: Validator<any>, requiredKeys: { [string]: boolean } }

local Config = {
	MaxDepth = 5,           
	MaxKeys = 100,          
	MaxStringLength = 100,  
}

local GlobalMetrics = {
	totalValidations = 0,
	totalErrors = 0,
	perSchema = {}, 
}

local compiledSchemas = setmetatable({}, { __mode = "k" })

local function createMetricsCollector(schemaName: string?): MetricsCollector
	local collector = {
		validations = 0,
		errors = 0,
		recordSuccess = function(self)
			self.validations += 1
		end,
		recordError = function(self, msg: string)
			self.errors += 1
		end,
	}
	return collector
end

local function finalizeMetrics(collector: MetricsCollector, schemaName: string?)
	GlobalMetrics.totalValidations += collector.validations
	GlobalMetrics.totalErrors += collector.errors
	if schemaName then
		if not GlobalMetrics.perSchema[schemaName] then
			GlobalMetrics.perSchema[schemaName] = { validations = 0, errors = 0 }
		end
		GlobalMetrics.perSchema[schemaName].validations += collector.validations
		GlobalMetrics.perSchema[schemaName].errors += collector.errors
	end
end

local function validateNumber(v: any, min: number?, max: number?): (boolean, number | string)
	if type(v) ~= "number" then
		return false, "expected number, got " .. type(v)
	end
	if v ~= v then -- NaN
		return false, "value is NaN"
	end
	if v == math.huge or v == -math.huge then
		return false, "value is infinite"
	end
	if min and v < min then
		return false, string.format("value %.2f is less than minimum %.2f", v, min)
	end
	if max and v > max then
		return false, string.format("value %.2f is greater than maximum %.2f", v, max)
	end
	return true, v
end

local function validateString(v: any, maxLen: number?): (boolean, string | string)
	if type(v) ~= "string" then
		return false, "expected string, got " .. type(v)
	end
	local limit = maxLen or Config.MaxStringLength
	if #v > limit then
		return false, string.format("string length %d exceeds maximum %d", #v, limit)
	end
	return true, v
end

local function validateTable(v: any, schema: CompiledSchema, depth: number, seen: { [any]: boolean }, context: ValidationContext): (boolean, any)
	if type(v) ~= "table" then
		return false, "expected table, got " .. type(v)
	end

	if seen[v] then
		return false, "circular reference detected"
	end
	if depth > Config.MaxDepth then
		return false, "maximum depth exceeded"
	end

	seen[v] = true
	local count = 0
	local result = {}

	for key, required in pairs(schema.requiredKeys) do
		if v[key] == nil then
			return false, string.format("missing required key '%s'", key)
		end
	end

	for key, value in pairs(v) do
		count += 1
		if count > Config.MaxKeys then
			return false, "table exceeds maximum number of keys"
		end

		local validator = schema.validator[key]
		if not validator then
			return false, string.format("unexpected key '%s'", key)
		end

		local subContext = {
			path = context.path .. "." .. key,
			metrics = context.metrics,
		}
		local ok, resultValue = validator(value, subContext)
		if not ok then
			return false, string.format("error at '%s': %s", subContext.path, resultValue)
		end
		result[key] = resultValue
	end

	return true, result
end


local Types = {}

function Types.string(maxLen: number?): Validator<string>
	return function(v: any, ctx: ValidationContext?): (boolean, string | string)
		local ok, res = validateString(v, maxLen)
		if ok then
			if ctx then ctx.metrics:recordSuccess() end
			return true, res
		else
			if ctx then ctx.metrics:recordError(res) end
			return false, res
		end
	end
end

function Types.number(min: number?, max: number?): Validator<number>
	return function(v: any, ctx: ValidationContext?): (boolean, number | string)
		local ok, res = validateNumber(v, min, max)
		if ok then
			if ctx then ctx.metrics:recordSuccess() end
			return true, res
		else
			if ctx then ctx.metrics:recordError(res) end
			return false, res
		end
	end
end

function Types.boolean(): Validator<boolean>
	return function(v: any, ctx: ValidationContext?): (boolean, boolean | string)
		if type(v) ~= "boolean" then
			if ctx then ctx.metrics:recordError("expected boolean") end
			return false, "expected boolean"
		end
		if ctx then ctx.metrics:recordSuccess() end
		return true, v
	end
end

function Types.literal(value: any): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if v == value then
			if ctx then ctx.metrics:recordSuccess() end
			return true, v
		end
		if ctx then ctx.metrics:recordError(string.format("expected '%s', got '%s'", tostring(value), tostring(v))) end
		return false, string.format("expected '%s'", tostring(value))
	end
end

function Types.array(elementValidator: Validator<any>): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if type(v) ~= "table" then
			if ctx then ctx.metrics:recordError("expected array (table)") end
			return false, "expected array"
		end
		local maxIdx = 0
		for k in pairs(v) do
			if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
				if ctx then ctx.metrics:recordError("array must have integer keys starting at 1") end
				return false, "array must have integer keys starting at 1"
			end
			if k > maxIdx then maxIdx = k end
		end
		for i = 1, maxIdx do
			if v[i] == nil then
				if ctx then ctx.metrics:recordError("array has missing index") end
				return false, "array has missing index"
			end
		end

		local result = {}
		for i = 1, maxIdx do
			local subCtx = ctx and {
				path = (ctx.path or "") .. "[" .. i .. "]",
				metrics = ctx.metrics,
			} or nil
			local ok, elem = elementValidator(v[i], subCtx)
			if not ok then
				return false, string.format("array element %d: %s", i, elem)
			end
			result[i] = elem
		end
		if ctx then ctx.metrics:recordSuccess() end
		return true, result
	end
end

function Types.table(): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if type(v) ~= "table" then
			if ctx then ctx.metrics:recordError("expected table") end
			return false, "expected table"
		end
		if ctx then ctx.metrics:recordSuccess() end
		return true, v
	end
end

function Types.any(): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if ctx then ctx.metrics:recordSuccess() end
		return true, v
	end
end

function Types.nil(): Validator<nil>
	return function(v: any, ctx: ValidationContext?): (boolean, nil | string)
		if v == nil then
			if ctx then ctx.metrics:recordSuccess() end
			return true, nil
		end
		if ctx then ctx.metrics:recordError("expected nil") end
		return false, "expected nil"
	end
end

function Types.optional(validator: Validator<any>): Validator<any>
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		if v == nil then
			if ctx then ctx.metrics:recordSuccess() end
			return true, nil
		end
		return validator(v, ctx)
	end
end

function Types.oneOf(...: Validator<any>): Validator<any>
	local validators = { ... }
	return function(v: any, ctx: ValidationContext?): (boolean, any | string)
		local lastError
		for _, validator in ipairs(validators) do
			local ok, res = validator(v, ctx)
			if ok then
				return true, res
			else
				lastError = res
			end
		end
		if ctx then ctx.metrics:recordError("oneOf failed: " .. tostring(lastError)) end
		return false, "value does not match any of the allowed types"
	end
end

function Types.schema(schemaConfig: SchemaConfig): Validator<any>
	-- Verificar se já está compilado
	if compiledSchemas[schemaConfig] then
		return compiledSchemas[schemaConfig].validator
	end

	local requiredKeys = {}
	local validatorMap = {}
	for key, validator in pairs(schemaConfig) do
		validatorMap[key] = validator
	end

	local compiled = {
		validator = validatorMap,
		requiredKeys = requiredKeys, -- não usado agora
	}

	
	local function schemaValidator(data: any, ctx: ValidationContext?): (boolean, any | string)
		if type(data) ~= "table" then
			if ctx then ctx.metrics:recordError("expected table") end
			return false, "expected table"
		end

		local localCtx = ctx or {
			path = "",
			metrics = createMetricsCollector(),
		}
		local seen = {}
		local ok, result = validateTable(data, compiled, 1, seen, localCtx)
		if ok then
			if ctx then
				ctx.metrics:recordSuccess()
			else
				localCtx.metrics:recordSuccess()
				finalizeMetrics(localCtx.metrics, nil) -- sem nome de schema, apenas globais
			end
			return true, result
		else
			if ctx then
				ctx.metrics:recordError(result)
			else
				localCtx.metrics:recordError(result)
				finalizeMetrics(localCtx.metrics, nil)
			end
			return false, result
		end
	end

	compiledSchemas[schemaConfig] = { validator = schemaValidator, requiredKeys = requiredKeys }
	return schemaValidator
end

local Metrics = {}

function Metrics.get()
	return {
		totalValidations = GlobalMetrics.totalValidations,
		totalErrors = GlobalMetrics.totalErrors,
		perSchema = GlobalMetrics.perSchema,
	}
end

function Metrics.reset()
	GlobalMetrics.totalValidations = 0
	GlobalMetrics.totalErrors = 0
	GlobalMetrics.perSchema = {}
end

function Metrics.setConfig(newConfig: { MaxDepth?: number, MaxKeys?: number, MaxStringLength?: number })
	if newConfig.MaxDepth then Config.MaxDepth = newConfig.MaxDepth end
	if newConfig.MaxKeys then Config.MaxKeys = newConfig.MaxKeys end
	if newConfig.MaxStringLength then Config.MaxStringLength = newConfig.MaxStringLength end
end

local ValidatorCore = {
	Types = Types,
	Metrics = Metrics,
	Config = Config, -- expor apenas leitura? vamos expor como tabela só para consulta
}

return ValidatorCore
