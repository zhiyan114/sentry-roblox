--!nocheck
--// Initialization

local Defaults = require(script.Parent:WaitForChild("Defaults"))

local ClientClass = require(script:WaitForChild("Client"))
local ScopeClass = require(script:WaitForChild("Scope"))

local Utils = require(script.Parent.Utils)

--[=[
	@class Hub
	
	The hub consists of a stack of clients and scopes.
	
	The SDK maintains two variables: The main hub (a global variable) and the current
	hub (a variable local to the current thread or execution context, also sometimes
	known as async local or context local).
]=]
local Hub = {}
Hub.logger = {}

--// Functions

--[=[
	@param Client Client
	@param Scope Scope
]=]
function Hub.new(Client: ClientClass.Client?, Scope: ScopeClass.Scope?)
	local mainTab = setmetatable({Client = Client or ClientClass.new(), Scope = Scope or ScopeClass.new()}, {__index = Hub})
	mainTab.logger.Hub = mainTab
	return mainTab
end


--[=[
]=]
function Hub:Clone()
	return Hub.new(self.Client, self.Scope:Clone())
end

--[=[
]=]
function Hub:GetCurrentHub()
	return self
end

--[=[
	@param Event Event
	@param Hint Hint
]=]
function Hub:CaptureEvent(Event: Defaults.Event, Hint)
	if self.Options then
		if self.Options.SampleRate == 0 then return end
		if math.random() > self.Options.SampleRate then
			return
		end
	end
	
	return self.Client:CaptureEvent(Event, Hint, self.Scope)
end

--[=[
	@param Level Level
]=]
function Hub:CaptureMessage(Message: string, Level: Defaults.Level? )
	return self:CaptureEvent({
		level = Level or "info",
		message = {
			formatted = Message, --// TODO: Remove PII (player names, user IDs)
			message = Message,
		}
	})
end



--[=[
  @param body string or logger.fmt content
  @param attribute any key/value (string, number, or bool)
]=]
function Hub.logger:info(body: string | Defaults.LogParamFormat, attribute: {[string]: any})
	return self:CaptureLog(body, attribute, "info");
end

--[=[
  @param body string or logger.fmt content
  @param attribute any key/value (string, number, or bool)
]=]
function Hub.logger:warn(body: string | Defaults.LogParamFormat, attribute: {[string]: any})
	return self:CaptureLog(body, attribute, "warn");
end

--[=[
  @param body string or logger.fmt content
  @param attribute any key/value (string, number, or bool)
]=]
function Hub.logger:error(body: string | Defaults.LogParamFormat, attribute: {[string]: any})
	return self:CaptureLog(body, attribute, "error");
end

--[=[
	@param template 'string.format' text template
	@param ... 'string.format' parameters to complete the template
]=]
function Hub.logger:fmt(template: string, ...: string): Defaults.LogParamFormat
	local content = {}
	content.template = template
	content.params = {...}
	return content;
end

--[=[
  @param body string or logger.fmt content
  @param attributes custom log metadata (key/value)
  @param level level
]=]
function Hub.logger:CaptureLog(body: string | Defaults.LogParamFormat, attributes: {[string]: any}, level: Defaults.Level)
	if not body then return; end
	if not self.Hub.Options.enableLogs then return; end
	local LogPayload = {
		timestamp = DateTime.now().UnixTimestamp;
		level = level or "info"; -- set default level if needed
		body = body;
		attributes = {
			["sentry.environment"] = self.Hub.Options.Environment;
			["sentry.release"] = self.Hub.Options.Release;
		};
	}

	-- Convert Formatted body to payload
	if typeof(LogPayload.body) == "table" then
		LogPayload.body = string.format(body.template, table.unpack(body.params));
		LogPayload.attributes["sentry.message.template"] = {
			value = body.template,
			type = "string" -- I trust that this will only be a string...
		}
		for i,v in ipairs(body.params) do
			local oType = type(v);
			if(oType ~= "string" and oType ~= "number" and oType ~= "boolean") then
				v = tostring(v); -- Force string if it's other than number or bool
				oType = "string";
			end
			if(oType == "number") then
				if v%1 == 0 then oType = "integer"
				else oType = "double" end
			end
			LogPayload.attributes["sentry.message.parameter."..i-1] = {
				value = v;
				type = oType;
			}
		end
	end

	-- Copy over attribute table
	for k,v in pairs(attributes) do
		local oType = type(v);
		if(oType ~= "string" and oType ~= "number" and oType ~= "boolean") then
			v = tostring(v); -- Force string if it's other than number or bool
			oType = "string";
		end
		if(oType == "number") then
			if v%1 == 0 then oType = "integer"
			else oType = "double" end
		end
		LogPayload.attributes[k] = {
			value = v,
			type = oType
		}
	end

	-- Copy over user attributes
	if self.Hub.Scope.user then
		local userObj = Utils.flattenTable(self.Hub.Scope.user, "user")
		for k,v in pairs(userObj) do
			LogPayload.attributes[k] = v;
		end
	end

	-- Server/Client ctx
	if self.Hub.Scope.logger then
		LogPayload.attributes.logger = self.Hub.Scope.logger;
	end

	if self.Options and self.Options.beforeSendLog then
		local newPayload = self.Options.beforeSendLog(LogPayload);
		if newPayload == nil then return; end
		return self.Hub.Client:CaptureLog(newPayload, self.Hub.Scope)
	end
	return self.Hub.Client:CaptureLog(LogPayload, self.Hub.Scope)
end

--[=[
]=]
function Hub:CaptureException(ErrorMessage: string?)
	if ErrorMessage == nil then
		return function(...)
			return self:CaptureException(...)
		end
	end
	
	local Thread = coroutine.running()
	local Event = {
		exception = {{
			type = ErrorMessage,
			thread_id = string.gsub(tostring(Thread), "thread: ", ""),
		}},
	}
	
	local EnvTrace = {}
	local EnvCount = 1
	
	if self.Options and self.Options.IncludeLocalVariables then
		while pcall(function() table.insert(EnvTrace, EnvCount, getfenv(EnvCount)) end) do
			EnvCount += 1
		end
	end
	
	local OriginEnv = EnvTrace[1]
	
	if OriginEnv then
		if OriginEnv.script then
			Event.exception[1].module = tostring(OriginEnv.script)
			Event.exception[1].thread_id = Event.exception[1].thread_id
		end
	end
	
	return self:CaptureEvent(Event, {
		message = ErrorMessage,
		traceback = debug.traceback(),
		environments = EnvTrace,
		memory_category = debug.getmemorycategory(),
		
		thread = Thread,
		thread_id = Event.exception[1].thread_id,
	})
end


--[=[
]=]
function Hub:PushScope()
	local OldScope = self.Scope
	local NewScope = setmetatable(Defaults:DeepCopy(OldScope), {__index = OldScope})
	
	self.Scope = NewScope
	
	return self, function()
		self.Scope = OldScope
	end
end

--[=[
	@unreleased
]=]
function Hub:WithScope()
	
end

--[=[
	@unreleased
]=]
function Hub:PopScope()
	self.Scope = getmetatable(self.Scope).__index
	
	return self
end

--[=[
]=]
function Hub:ConfigureScope(Callback: (ScopeClass.Scope) -> ())
	self.Scope:ConfigureScope(Callback)
	
	return self
end


--[=[
]=]
function Hub:GetClient()
	return self.Client
end

--[=[
	@param Client Client
]=]
function Hub:BindClient(Client: any?)
	self.Client = Client
end

--[=[
]=]
function Hub:UnbindClient()
	return self:BindClient(nil)
end

--[=[
]=]
function Hub:StartSession()
	local CurrentTime = DateTime.now()
	
	return self.Options.Transport:CaptureEnvelope({
		sid = self.Scope.user.sid,
		did = tostring(self.Scope.user.id),
		seq = CurrentTime.UnixTimestampMillis,
		timestamp = CurrentTime:ToIsoDate(),
		started = self.Scope.user.started:ToIsoDate(),
		init = true,
		
		status = "ok",
		
		attrs = {
			release = self.Scope.release,
			environment = self.Scope.environment,
		}
	})
end

--[=[
]=]
function Hub:EndSession()
	local CurrentTime = DateTime.now()
	
	return self.Options.Transport:CaptureEnvelope({
		sid = self.Scope.user.sid,
		did = tostring(self.Scope.user.id),
		seq = CurrentTime.UnixTimestampMillis,
		timestamp = CurrentTime:ToIsoDate(),
		started = self.Scope.user.started:ToIsoDate(),
		
		status = "exited",
		
		attrs = {
			release = self.Scope.release,
			environment = self.Scope.environment,
		}
	})
end

return Hub