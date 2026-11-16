namespace ServiceLib.Models.Dto;

public enum SubscriptionUpdateOutcomeKind { Succeeded, Failed, Skipped }
public sealed record SubscriptionUpdateOutcome(string Id, SubscriptionUpdateOutcomeKind Kind);
