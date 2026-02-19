local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local AIModule = {}

local DATASTORE_NAME = "NavLearnV1"
local FLUSH_INTERVAL = 45
local MAX_FLUSHED_SHARDS_PER_TICK = 3
local MAX_CELLS_PER_SHARD = 1600
local MAX_EDGES_PER_SHARD = 2800
local DEFAULT_CELL_SIZE = 12
local DEFAULT_SHARD_SIZE = 288
local DEFAULT_STUCK_SECONDS = 1.2
local DEFAULT_MIN_PROGRESS = 1.0
local DEFAULT_REROUTE_COOLDOWN = 0.6
local DEFAULT_NODE_EXPANSION_CAP = 320
local DEFAULT_LOS_HEIGHT = 2.0
local DEFAULT_LOCAL_AVOIDANCE_RANGE = 18
local DEFAULT_FAILURE_RATE_WEIGHT = 3.5
local DEFAULT_TIME_WEIGHT = 0.25
local DEFAULT_DECAY_HALF_LIFE = 900
local DEFAULT_BLOCKED_SKIP_CONFIDENCE = 0.9
local DEFAULT_SUCCESS_COST_DECAY = 0.03
local DEFAULT_FAILURE_COST_INCREASE = 0.15
local DEFAULT_EXPLORATION_SECONDS = 3
local DEFAULT_EXPLORATION_ANGLE = 35

local DataStore = nil
pcall(function()
	DataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
end)

local RuntimeState = {
	AgentStates = {},
	ShardCache = {},
	PendingUpdates = {},
	LastFlush = 0,
	SessionNonce = HttpService:GenerateGUID(false),
}

local function GetRootPart(AI)
	if typeof(AI) ~= "Instance" then
		return nil
	end
	if AI:IsA("BasePart") then
		return AI
	end
	if AI:IsA("Model") then
		return AI.PrimaryPart
	end
	return nil
end

local function GetAgentId(RootPart)
	local Existing = RootPart:GetAttribute("NavAgentId")
	if type(Existing) == "string" and #Existing > 0 then
		return Existing
	end
	local NewId = HttpService:GenerateGUID(false)
	pcall(function()
		RootPart:SetAttribute("NavAgentId", NewId)
	end)
	return NewId
end

local function GetNow()
	return os.clock()
end

local function GetParams(Params, Name, Default)
	if Params and Params[Name] ~= nil then
		return Params[Name]
	end
	return Default
end

local function GetMapVersion(Params)
	return tostring(GetParams(Params, "MapVersion", "v1"))
end

local function GetCellSize(Params)
	return GetParams(Params, "CellSize", DEFAULT_CELL_SIZE)
end

local function GetShardSize(Params)
	return GetParams(Params, "ShardSize", DEFAULT_SHARD_SIZE)
end

local function ToCell(Position, CellSize)
	return math.floor(Position.X / CellSize), math.floor(Position.Z / CellSize)
end

local function CellToCenter(CellX, CellZ, CellSize, Y)
	return Vector3.new((CellX + 0.5) * CellSize, Y, (CellZ + 0.5) * CellSize)
end

local function CellKey(CellX, CellZ)
	return tostring(CellX) .. "," .. tostring(CellZ)
end

local function EdgeKey(FromX, FromZ, ToX, ToZ)
	return tostring(FromX) .. "," .. tostring(FromZ) .. ">" .. tostring(ToX) .. "," .. tostring(ToZ)
end

local function GetShardCoords(CellX, CellZ, Params)
	local ShardSize = GetShardSize(Params)
	local CellSize = GetCellSize(Params)
	local CellsPerShard = math.max(1, math.floor(ShardSize / CellSize))
	return math.floor(CellX / CellsPerShard), math.floor(CellZ / CellsPerShard)
end

local function ShardId(MapVersion, ShardX, ShardZ)
	return MapVersion .. ":" .. tostring(ShardX) .. ":" .. tostring(ShardZ)
end

local function DataStoreKey(MapVersion, ShardX, ShardZ)
	return "NavLearn:" .. tostring(game.PlaceId) .. ":" .. MapVersion .. ":" .. tostring(ShardX) .. ":" .. tostring(ShardZ)
end

local function EnsureShardLoaded(CellX, CellZ, Params)
	local MapVersion = GetMapVersion(Params)
	local ShardX, ShardZ = GetShardCoords(CellX, CellZ, Params)
	local Id = ShardId(MapVersion, ShardX, ShardZ)
	local Cached = RuntimeState.ShardCache[Id]
	if Cached then
		return Cached, Id
	end

	local Loaded = {
		MapVersion = MapVersion,
		ShardX = ShardX,
		ShardZ = ShardZ,
		LoadedAt = GetNow(),
		Cells = {},
		Edges = {},
	}

	if DataStore then
		local Success, Result = pcall(function()
			return DataStore:GetAsync(DataStoreKey(MapVersion, ShardX, ShardZ))
		end)
		if Success and type(Result) == "table" then
			Loaded.Cells = type(Result.Cells) == "table" and Result.Cells or {}
			Loaded.Edges = type(Result.Edges) == "table" and Result.Edges or {}
		end
	end

	RuntimeState.ShardCache[Id] = Loaded
	RuntimeState.PendingUpdates[Id] = RuntimeState.PendingUpdates[Id] or {Cells = {}, Edges = {}, Dirty = 0}
	return Loaded, Id
end

local function MergeStat(Target, Delta)
	Target.Attempts = (Target.Attempts or 0) + (Delta.Attempts or 0)
	Target.Successes = (Target.Successes or 0) + (Delta.Successes or 0)
	Target.Failures = (Target.Failures or 0) + (Delta.Failures or 0)
	Target.CostBias = math.max(0, (Target.CostBias or 0) + (Delta.CostBias or 0))
	if Delta.AvgTravelTime and Delta.AvgTravelTime > 0 then
		if not Target.AvgTravelTime or Target.AvgTravelTime <= 0 then
			Target.AvgTravelTime = Delta.AvgTravelTime
		else
			Target.AvgTravelTime = Target.AvgTravelTime * 0.8 + Delta.AvgTravelTime * 0.2
		end
	end
	Target.LastSeenTimestamp = os.time()
end

local function BoundedTrim(Dictionary, MaxSize)
	local Count = 0
	for _ in pairs(Dictionary) do
		Count += 1
	end
	if Count <= MaxSize then
		return
	end
	local Scored = {}
	for Key, Value in pairs(Dictionary) do
		local Score = (Value.Successes or 0) + (Value.Attempts or 0) + ((Value.LastSeenTimestamp or 0) % 1000) * 0.001
		table.insert(Scored, {Key = Key, Score = Score})
	end
	table.sort(Scored, function(A, B)
		return A.Score > B.Score
	end)
	for Index = MaxSize + 1, #Scored do
		Dictionary[Scored[Index].Key] = nil
	end
end

local function RecordDelta(Id, Kind, Key, Delta)
	local Pending = RuntimeState.PendingUpdates[Id]
	if not Pending then
		Pending = {Cells = {}, Edges = {}, Dirty = 0}
		RuntimeState.PendingUpdates[Id] = Pending
	end
	local Bucket = Pending[Kind]
	if not Bucket[Key] then
		Bucket[Key] = {}
	end
	MergeStat(Bucket[Key], Delta)
	Pending.Dirty += 1
end

local function RecordCellEvent(CellX, CellZ, Params, IsSuccess, TravelTime)
	local Shard, Id = EnsureShardLoaded(CellX, CellZ, Params)
	local Key = CellKey(CellX, CellZ)
	Shard.Cells[Key] = Shard.Cells[Key] or {Attempts = 0, Successes = 0, Failures = 0, CostBias = 0, LastSeenTimestamp = os.time()}
	local Delta = {
		Attempts = 1,
		Successes = IsSuccess and 1 or 0,
		Failures = IsSuccess and 0 or 1,
		AvgTravelTime = TravelTime,
		CostBias = IsSuccess and -DEFAULT_SUCCESS_COST_DECAY or DEFAULT_FAILURE_COST_INCREASE,
	}
	MergeStat(Shard.Cells[Key], Delta)
	RecordDelta(Id, "Cells", Key, Delta)
end

local function RecordEdgeEvent(FromX, FromZ, ToX, ToZ, Params, IsSuccess, TravelTime)
	local Shard, Id = EnsureShardLoaded(FromX, FromZ, Params)
	local Key = EdgeKey(FromX, FromZ, ToX, ToZ)
	Shard.Edges[Key] = Shard.Edges[Key] or {Attempts = 0, Successes = 0, Failures = 0, CostBias = 0, LastSeenTimestamp = os.time()}
	local Delta = {
		Attempts = 1,
		Successes = IsSuccess and 1 or 0,
		Failures = IsSuccess and 0 or 1,
		AvgTravelTime = TravelTime,
		CostBias = IsSuccess and -DEFAULT_SUCCESS_COST_DECAY or DEFAULT_FAILURE_COST_INCREASE,
	}
	MergeStat(Shard.Edges[Key], Delta)
	RecordDelta(Id, "Edges", Key, Delta)
end

local function FlushDataStore(Force)
	if not DataStore then
		return
	end
	local Now = GetNow()
	if not Force and (Now - RuntimeState.LastFlush) < FLUSH_INTERVAL then
		return
	end
	RuntimeState.LastFlush = Now

	local Flushed = 0
	for Id, Pending in pairs(RuntimeState.PendingUpdates) do
		if Pending.Dirty > 0 then
			local MapVersion, ShardXStr, ShardZStr = string.match(Id, "([^:]+):([^:]+):([^:]+)")
			local ShardX = tonumber(ShardXStr)
			local ShardZ = tonumber(ShardZStr)
			if MapVersion and ShardX and ShardZ then
				pcall(function()
					DataStore:UpdateAsync(DataStoreKey(MapVersion, ShardX, ShardZ), function(Old)
						local Merged = type(Old) == "table" and Old or {Cells = {}, Edges = {}, LastWriter = ""}
						Merged.Cells = type(Merged.Cells) == "table" and Merged.Cells or {}
						Merged.Edges = type(Merged.Edges) == "table" and Merged.Edges or {}

						for Key, Delta in pairs(Pending.Cells) do
							Merged.Cells[Key] = Merged.Cells[Key] or {Attempts = 0, Successes = 0, Failures = 0, CostBias = 0}
							MergeStat(Merged.Cells[Key], Delta)
						end
						for Key, Delta in pairs(Pending.Edges) do
							Merged.Edges[Key] = Merged.Edges[Key] or {Attempts = 0, Successes = 0, Failures = 0, CostBias = 0}
							MergeStat(Merged.Edges[Key], Delta)
						end
						BoundedTrim(Merged.Cells, MAX_CELLS_PER_SHARD)
						BoundedTrim(Merged.Edges, MAX_EDGES_PER_SHARD)
						Merged.LastWriter = RuntimeState.SessionNonce
						Merged.UpdatedAt = os.time()
						return Merged
					end)
				end)
			end
			RuntimeState.PendingUpdates[Id] = {Cells = {}, Edges = {}, Dirty = 0}
			Flushed += 1
			if not Force and Flushed >= MAX_FLUSHED_SHARDS_PER_TICK then
				break
			end
		end
	end
end

local function BuildRaycastParams(RootPart, Params)
	local RaycastParamsValue = RaycastParams.new()
	RaycastParamsValue.FilterType = Enum.RaycastFilterType.Exclude
	local IgnoreList = {RootPart}
	if Params and type(Params.RaycastIgnore) == "table" then
		for _, Item in ipairs(Params.RaycastIgnore) do
			table.insert(IgnoreList, Item)
		end
	end
	RaycastParamsValue.FilterDescendantsInstances = IgnoreList
	RaycastParamsValue.IgnoreWater = true
	return RaycastParamsValue
end

local function DrawDebugRay(StartPosition, Direction, IsHit)
	local Marker = Instance.new("Part")
	Marker.Anchored = true
	Marker.CanCollide = false
	Marker.Material = Enum.Material.Neon
	Marker.Color = IsHit and Color3.new(1, 0.25, 0.25) or Color3.new(0.25, 1, 0.25)
	local Length = Direction.Magnitude
	Marker.Size = Vector3.new(0.15, 0.15, math.max(0.15, Length))
	Marker.CFrame = CFrame.new(StartPosition, StartPosition + Direction) * CFrame.new(0, 0, -Length * 0.5)
	Marker.Parent = Workspace
	Debris:AddItem(Marker, 0.1)
end

local function DrawDebugPath(Path, Height)
	for _, Waypoint in ipairs(Path) do
		local Dot = Instance.new("Part")
		Dot.Shape = Enum.PartType.Ball
		Dot.Anchored = true
		Dot.CanCollide = false
		Dot.Material = Enum.Material.Neon
		Dot.Color = Color3.new(0.2, 0.8, 1)
		Dot.Size = Vector3.new(0.7, 0.7, 0.7)
		Dot.Position = Vector3.new(Waypoint.X, Height, Waypoint.Z)
		Dot.Parent = Workspace
		Debris:AddItem(Dot, 0.6)
	end
end

local function DecayedFailureRate(Stat, Params)
	if not Stat then
		return 0, 0
	end
	local Attempts = Stat.Attempts or 0
	if Attempts <= 0 then
		return 0, Stat.CostBias or 0
	end
	local LastSeen = Stat.LastSeenTimestamp or os.time()
	local Age = math.max(0, os.time() - LastSeen)
	local HalfLife = GetParams(Params, "DecayHalfLife", DEFAULT_DECAY_HALF_LIFE)
	local DecayMultiplier = math.pow(0.5, Age / math.max(1, HalfLife))
	local Failures = (Stat.Failures or 0) * DecayMultiplier
	local Successes = (Stat.Successes or 0) + 0.001
	local FailureRate = Failures / (Failures + Successes)
	return FailureRate, Stat.CostBias or 0
end

local function TraversalCost(FromX, FromZ, ToX, ToZ, DistanceCost, Params)
	local Shard = EnsureShardLoaded(FromX, FromZ, Params)
	local Cells = Shard.Cells
	local Edges = Shard.Edges
	local CellStat = Cells[CellKey(ToX, ToZ)]
	local EdgeStat = Edges[EdgeKey(FromX, FromZ, ToX, ToZ)]
	local FailureRateWeight = GetParams(Params, "FailureRateWeight", DEFAULT_FAILURE_RATE_WEIGHT)
	local TimeWeight = GetParams(Params, "TravelTimeWeight", DEFAULT_TIME_WEIGHT)
	local CellFailureRate, CellBias = DecayedFailureRate(CellStat, Params)
	local EdgeFailureRate, EdgeBias = DecayedFailureRate(EdgeStat, Params)
	local FailurePenalty = 1 + FailureRateWeight * math.max(CellFailureRate, EdgeFailureRate)
	local TimePenalty = 1
	if EdgeStat and EdgeStat.AvgTravelTime and EdgeStat.AvgTravelTime > 0 then
		TimePenalty += TimeWeight * math.min(3, EdgeStat.AvgTravelTime / 2)
	end
	local BiasPenalty = 1 + math.max(0, CellBias + EdgeBias)
	local BlockedConfidence = math.max(CellFailureRate, EdgeFailureRate)
	return DistanceCost * FailurePenalty * TimePenalty * BiasPenalty, BlockedConfidence
end

local function MinOpenSet(OpenSet, FScore)
	local BestIndex = 1
	local BestNode = OpenSet[1]
	local BestF = FScore[BestNode] or math.huge
	for Index = 2, #OpenSet do
		local Node = OpenSet[Index]
		local Score = FScore[Node] or math.huge
		if Score < BestF then
			BestF = Score
			BestNode = Node
			BestIndex = Index
		end
	end
	return BestIndex, BestNode
end

local function ReconstructPath(CameFrom, CurrentNode, CellSize, Height)
	local Path = {}
	while CurrentNode do
		local XStr, ZStr = string.match(CurrentNode, "([^,]+),([^,]+)")
		local CellX = tonumber(XStr)
		local CellZ = tonumber(ZStr)
		table.insert(Path, 1, CellToCenter(CellX, CellZ, CellSize, Height))
		CurrentNode = CameFrom[CurrentNode]
	end
	return Path
end

-- Layer 3 uses A* over a learned top-down grid. Costs come from learned edge/cell stats.
local function ComputeLearnedPath(StartPosition, GoalPosition, Height, Params)
	local CellSize = GetCellSize(Params)
	local StartX, StartZ = ToCell(StartPosition, CellSize)
	local GoalX, GoalZ = ToCell(GoalPosition, CellSize)
	EnsureShardLoaded(StartX, StartZ, Params)
	EnsureShardLoaded(GoalX, GoalZ, Params)

	local StartNode = CellKey(StartX, StartZ)
	local GoalNode = CellKey(GoalX, GoalZ)
	local OpenSet = {StartNode}
	local CameFrom = {}
	local GScore = {[StartNode] = 0}
	local FScore = {[StartNode] = (Vector2.new(StartX, StartZ) - Vector2.new(GoalX, GoalZ)).Magnitude}
	local ClosedSet = {}
	local ExpansionCap = GetParams(Params, "NodeExpansionCap", DEFAULT_NODE_EXPANSION_CAP)
	local AllowDiagonal = GetParams(Params, "AllowDiagonal", true)

	local Offsets = AllowDiagonal and {
		{1, 0}, {-1, 0}, {0, 1}, {0, -1},
		{1, 1}, {-1, 1}, {1, -1}, {-1, -1},
	} or {
		{1, 0}, {-1, 0}, {0, 1}, {0, -1},
	}

	local Expansions = 0
	while #OpenSet > 0 do
		local BestIndex, Current = MinOpenSet(OpenSet, FScore)
		table.remove(OpenSet, BestIndex)
		if Current == GoalNode then
			local Path = ReconstructPath(CameFrom, Current, CellSize, Height)
			if #Path > 0 then
				table.remove(Path, 1)
			end
			return Path
		end

		ClosedSet[Current] = true
		local CurXStr, CurZStr = string.match(Current, "([^,]+),([^,]+)")
		local CurX = tonumber(CurXStr)
		local CurZ = tonumber(CurZStr)

		for _, Offset in ipairs(Offsets) do
			local NextX = CurX + Offset[1]
			local NextZ = CurZ + Offset[2]
			local Neighbor = CellKey(NextX, NextZ)
			if not ClosedSet[Neighbor] then
				local BaseDistance = (Vector2.new(CurX, CurZ) - Vector2.new(NextX, NextZ)).Magnitude
				local StepCost, BlockedConfidence = TraversalCost(CurX, CurZ, NextX, NextZ, BaseDistance, Params)
				local SkipThreshold = GetParams(Params, "BlockedSkipConfidence", DEFAULT_BLOCKED_SKIP_CONFIDENCE)
				if BlockedConfidence < SkipThreshold or Neighbor == GoalNode then
					local TentativeG = (GScore[Current] or math.huge) + StepCost
					if TentativeG < (GScore[Neighbor] or math.huge) then
						CameFrom[Neighbor] = Current
						GScore[Neighbor] = TentativeG
						FScore[Neighbor] = TentativeG + (Vector2.new(NextX, NextZ) - Vector2.new(GoalX, GoalZ)).Magnitude
						local Seen = false
						for _, Existing in ipairs(OpenSet) do
							if Existing == Neighbor then
								Seen = true
								break
							end
						end
						if not Seen then
							table.insert(OpenSet, Neighbor)
						end
					end
				end
			end
		end

		Expansions += 1
		if Expansions >= ExpansionCap then
			break
		end
	end

	return nil
end

local function IsDirectionClearWithClearance(ProbeStart, ProbeDirection, RaycastParamsValue, Clearance, DebugRays)
	local Length = ProbeDirection.Magnitude
	if Length <= 0.001 then
		return true
	end
	local UnitDir = ProbeDirection / Length
	local Perp = Vector3.new(-UnitDir.Z, 0, UnitDir.X)
	local SideOffset = Perp * math.max(0.15, Clearance * 0.85)

	local Starts = {
		ProbeStart,
		ProbeStart + SideOffset,
		ProbeStart - SideOffset,
	}

	for _, Start in ipairs(Starts) do
		local Hit = Workspace:Raycast(Start, ProbeDirection, RaycastParamsValue)
		if DebugRays then
			DrawDebugRay(Start, ProbeDirection, Hit ~= nil)
		end
		if Hit then
			return false
		end
	end

	return true
end

local function TryLocalAvoidance(StartPosition, DesiredDirection, Clearance, RootPart, Params, Height)
	local RaycastParamsValue = BuildRaycastParams(RootPart, Params)
	local Range = GetParams(Params, "LocalAvoidanceRange", DEFAULT_LOCAL_AVOIDANCE_RANGE)
	local Angles = {-70, -40, -20, 20, 40, 70}
	local ExplorationAngle = 0
	if Params and Params.ExplorationBiasAngle then
		ExplorationAngle = Params.ExplorationBiasAngle
	end

	local RootSize = RootPart.Size
	local LowHeight = math.max(0.5, RootSize.Y * 0.25)
	local DebugRays = Params and Params.DebugRays

	for _, Degrees in ipairs(Angles) do
		local Angle = math.rad(Degrees + ExplorationAngle)
		local Rotated = (CFrame.fromAxisAngle(Vector3.new(0, 1, 0), Angle):VectorToWorldSpace(DesiredDirection.Unit))
		local ProbeDirection = Rotated * (Range + Clearance)

		local ProbeStartHigh = StartPosition + Vector3.new(0, Height, 0)
		local ProbeStartLow = StartPosition + Vector3.new(0, LowHeight, 0)

		local HighClear = IsDirectionClearWithClearance(ProbeStartHigh, ProbeDirection, RaycastParamsValue, Clearance, DebugRays)
		local LowClear = IsDirectionClearWithClearance(ProbeStartLow, ProbeDirection, RaycastParamsValue, Clearance, DebugRays)

		if HighClear and LowClear then
			return Rotated
		end
	end
	return nil
end

local function IsLineClear(StartPosition, EndPosition, RootPart, Params, Height)
	local RaycastParamsValue = BuildRaycastParams(RootPart, Params)
	local Direction = EndPosition - StartPosition

	local RootSize = RootPart.Size
	local Clearance = math.max(RootSize.X, RootSize.Z) * 0.5
	local LowHeight = math.max(0.5, RootSize.Y * 0.25)

	local DebugRays = Params and Params.DebugRays
	local ProbeStartHigh = StartPosition + Vector3.new(0, Height, 0)
	local ProbeStartLow = StartPosition + Vector3.new(0, LowHeight, 0)

	if not IsDirectionClearWithClearance(ProbeStartHigh, Direction, RaycastParamsValue, Clearance, DebugRays) then
		return false
	end
	if not IsDirectionClearWithClearance(ProbeStartLow, Direction, RaycastParamsValue, Clearance, DebugRays) then
		return false
	end

	return true
end

local function Horizontal(Vector)
	return Vector3.new(Vector.X, 0, Vector.Z)
end

function AIModule.moveAI(Destination, Walkspeed, AI, Params)
	FlushDataStore(false)

	local RootPart = GetRootPart(AI)
	if not RootPart then
		return false, "Invalid AI"
	end
	if typeof(Destination) ~= "Vector3" then
		return false, "Invalid Destination"
	end

	local AgentId = GetAgentId(RootPart)
	local AgentState = RuntimeState.AgentStates[AgentId]
	if not AgentState then
		AgentState = {
			LastPosition = RootPart.Position,
			LastUpdate = GetNow(),
			StuckSeconds = 0,
			LastReroute = 0,
			Path = nil,
			PathIndex = 1,
			LastCellX = nil,
			LastCellZ = nil,
			LastCellTransition = GetNow(),
			StuckEvents = 0,
			ExplorationUntil = 0,
		}
		RuntimeState.AgentStates[AgentId] = AgentState
	end

	local Now = GetNow()
	local DeltaTime = math.max(1 / 60, Now - AgentState.LastUpdate)
	AgentState.LastUpdate = Now

	local CurrentPosition = RootPart.Position
	local ToDestination = Destination - CurrentPosition
	local HorizontalToDestination = Horizontal(ToDestination)
	local Distance = HorizontalToDestination.Magnitude
	if Distance < 1.5 then
		local ExistingVelocity = RootPart.AssemblyLinearVelocity
		RootPart.AssemblyLinearVelocity = Vector3.new(0, ExistingVelocity.Y, 0)
		return true, "Arrived"
	end

	local RootSize = RootPart.Size
	local Clearance = math.max(RootSize.X, RootSize.Z) * 0.5
	local ProbeHeight = math.max(RootSize.Y * 0.5, GetParams(Params, "LOSHeight", DEFAULT_LOS_HEIGHT))
	local CellSize = GetCellSize(Params)
	local CurrentCellX, CurrentCellZ = ToCell(CurrentPosition, CellSize)

	if AgentState.LastCellX ~= nil then
		if AgentState.LastCellX ~= CurrentCellX or AgentState.LastCellZ ~= CurrentCellZ then
			local TravelTime = math.max(0.05, Now - AgentState.LastCellTransition)
			RecordCellEvent(CurrentCellX, CurrentCellZ, Params, true, TravelTime)
			RecordEdgeEvent(AgentState.LastCellX, AgentState.LastCellZ, CurrentCellX, CurrentCellZ, Params, true, TravelTime)
			AgentState.LastCellTransition = Now
		end
	else
		AgentState.LastCellTransition = Now
	end
	AgentState.LastCellX = CurrentCellX
	AgentState.LastCellZ = CurrentCellZ

	local MovedDistance = (Horizontal(CurrentPosition - AgentState.LastPosition)).Magnitude
	local MinProgress = GetParams(Params, "MinProgressStuds", DEFAULT_MIN_PROGRESS)
	if MovedDistance < MinProgress * DeltaTime then
		AgentState.StuckSeconds += DeltaTime
	else
		AgentState.StuckSeconds = math.max(0, AgentState.StuckSeconds - DeltaTime * 0.5)
	end
	AgentState.LastPosition = CurrentPosition

	local StuckThreshold = GetParams(Params, "StuckSeconds", DEFAULT_STUCK_SECONDS)
	local IsStuck = AgentState.StuckSeconds >= StuckThreshold
	if IsStuck then
		RecordCellEvent(CurrentCellX, CurrentCellZ, Params, false, nil)
		if AgentState.LastCellX and AgentState.LastCellZ then
			RecordEdgeEvent(AgentState.LastCellX, AgentState.LastCellZ, CurrentCellX, CurrentCellZ, Params, false, nil)
		end
		AgentState.StuckEvents += 1
		AgentState.StuckSeconds = 0
		if AgentState.StuckEvents >= 2 then
			AgentState.ExplorationUntil = Now + GetParams(Params, "ExplorationSeconds", DEFAULT_EXPLORATION_SECONDS)
			AgentState.StuckEvents = 0
		end
	end

	local ExistingVelocity = RootPart.AssemblyLinearVelocity
	local DesiredVelocityXZ = Vector3.zero
	local HasLOS = IsLineClear(CurrentPosition, Destination, RootPart, Params, ProbeHeight)

	if HasLOS then
		DesiredVelocityXZ = HorizontalToDestination.Unit * Walkspeed
		AgentState.Path = nil
		AgentState.PathIndex = 1
	else
		local ExplorationBiasAngle = 0
		if Now < AgentState.ExplorationUntil then
			local ExplorationAngle = GetParams(Params, "ExplorationAngle", DEFAULT_EXPLORATION_ANGLE)
			ExplorationBiasAngle = (math.random() * 2 - 1) * ExplorationAngle
		end

		local AvoidanceDirection = TryLocalAvoidance(CurrentPosition, HorizontalToDestination, Clearance, RootPart, {
			DebugRays = Params and Params.DebugRays,
			RaycastIgnore = Params and Params.RaycastIgnore,
			LocalAvoidanceRange = GetParams(Params, "LocalAvoidanceRange", DEFAULT_LOCAL_AVOIDANCE_RANGE),
			ExplorationBiasAngle = ExplorationBiasAngle,
		}, ProbeHeight)

		if AvoidanceDirection then
			DesiredVelocityXZ = Horizontal(AvoidanceDirection).Unit * Walkspeed
		else
			local RerouteCooldown = GetParams(Params, "RerouteCooldown", DEFAULT_REROUTE_COOLDOWN)
			if not AgentState.Path or IsStuck or (Now - AgentState.LastReroute >= RerouteCooldown) then
				local Path = ComputeLearnedPath(CurrentPosition, Destination, CurrentPosition.Y, Params)
				AgentState.Path = Path
				AgentState.PathIndex = 1
				AgentState.LastReroute = Now
				if Params and Params.DebugPath and Path then
					DrawDebugPath(Path, CurrentPosition.Y)
				end
			end

			if AgentState.Path and AgentState.PathIndex <= #AgentState.Path then
				local Waypoint = AgentState.Path[AgentState.PathIndex]
				local ToWaypoint = Horizontal(Waypoint - CurrentPosition)
				if ToWaypoint.Magnitude < math.max(2, CellSize * 0.35) then
					AgentState.PathIndex += 1
				else
					if IsLineClear(CurrentPosition, Waypoint, RootPart, Params, ProbeHeight) then
						DesiredVelocityXZ = ToWaypoint.Unit * Walkspeed
					else
						AgentState.Path = nil
						AgentState.PathIndex = 1
					end
				end
			end
		end
	end

	if DesiredVelocityXZ.Magnitude <= 0.001 then
		DesiredVelocityXZ = Vector3.zero
	end

	RootPart.AssemblyLinearVelocity = Vector3.new(DesiredVelocityXZ.X, ExistingVelocity.Y, DesiredVelocityXZ.Z)

	if Params and Params.DebugTraining then
		local Shard = EnsureShardLoaded(CurrentCellX, CurrentCellZ, Params)
		local CellData = Shard.Cells[CellKey(CurrentCellX, CurrentCellZ)]
		if CellData then
			local FailureRate = (CellData.Failures or 0) / math.max(1, CellData.Attempts or 1)
			print(string.format("[NavLearn] Cell %d,%d Attempts=%d Success=%d Fail=%d FailureRate=%.2f", CurrentCellX, CurrentCellZ, CellData.Attempts or 0, CellData.Successes or 0, CellData.Failures or 0, FailureRate))
		end
	end

	return true, "Moving"
end

game:BindToClose(function()
	FlushDataStore(true)
end)
return AIModule
