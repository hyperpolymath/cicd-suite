module Assurance.Cabal

%default total

||| Evidence from the runner that will perform dependency resolution.
public export
data IndexState = Unknown | Available | Missing

||| A cache restore alone cannot establish index availability.
public export
data BuildPlan = RefreshThenResolve | Resolve

public export
planOnlineBuild : IndexState -> BuildPlan
planOnlineBuild Available = Resolve
planOnlineBuild Missing = RefreshThenResolve
planOnlineBuild Unknown = RefreshThenResolve

missingRefreshes : planOnlineBuild Missing = RefreshThenResolve
missingRefreshes = Refl

unknownRefreshes : planOnlineBuild Unknown = RefreshThenResolve
unknownRefreshes = Refl

availableResolves : planOnlineBuild Available = Resolve
availableResolves = Refl
