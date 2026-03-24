namespace BusKit.Sidecar.Models;

// Mirrors the AccessTier proto enum — do NOT change ordinal values.
public enum AccessTier : int
{
    NoAccess        = 0,
    ReadOnly        = 1,
    MessageReader   = 2,
    MessageOperator = 3,
    FullAccess      = 4,
}

public sealed record CapabilityMap
{
    public bool BrowseEntities  { get; init; }
    public bool ViewProperties  { get; init; }
    public bool PeekFetch       { get; init; }
    public bool Purge           { get; init; }
    public bool ResubmitDlq     { get; init; }
    public bool CreateResources { get; init; }
    public bool ManageFilters   { get; init; }

    public static readonly CapabilityMap None = new();
    public static readonly CapabilityMap All  = new()
    {
        BrowseEntities = true, ViewProperties = true, PeekFetch = true,
        Purge = true, ResubmitDlq = true, CreateResources = true, ManageFilters = true,
    };
}

public sealed record RoleUpgradeRecommendation
{
    public string     RoleName         { get; init; } = string.Empty;
    public string     RoleDefinitionId { get; init; } = string.Empty;
    public AccessTier TargetTier       { get; init; }
    public string     Description      { get; init; } = string.Empty;
}

public sealed record PermissionEvaluationResult
{
    public AccessTier                 Tier                  { get; init; }
    public bool                       IsPartialAccess       { get; init; }
    public string                     TierLabel             { get; init; } = string.Empty;
    public CapabilityMap              Capabilities          { get; init; } = CapabilityMap.None;
    public RoleUpgradeRecommendation? UpgradeRecommendation { get; init; }
    public bool                       EvaluationFailed      { get; init; }
    public string?                    ErrorMessage          { get; init; }
    public DateTimeOffset             EvaluatedAt           { get; init; }
    public DateTimeOffset             ExpiresAt             { get; init; }
}
