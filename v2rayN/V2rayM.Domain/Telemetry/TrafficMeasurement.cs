namespace V2rayM.Domain.Telemetry;

/// Measured KiB deltas over an interval, not an instantaneous rate.
public sealed record TrafficMeasurement(double ProxyUp, double ProxyDown, double DirectUp,
    double DirectDown, double SampleSeconds, DateTimeOffset SampledAt);
