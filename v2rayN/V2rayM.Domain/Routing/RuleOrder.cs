namespace V2rayM.Domain.Routing;

public enum RuleMove { Top, Up, Down, Bottom, Position }
public static class RuleOrder
{
    // Position is an insertion slot in the original list, including the end slot.
    public static int? Destination(int count, int index, RuleMove move, int position)
    {
        if (index < 0 || index >= count) return null;
        return move switch
        {
            RuleMove.Top => 0,
            RuleMove.Up => Math.Max(0, index - 1),
            RuleMove.Down => Math.Min(count - 1, index + 1),
            RuleMove.Bottom => count - 1,
            RuleMove.Position when position >= 0 && position <= count => position > index ? position - 1 : position,
            _ => null,
        };
    }
}
