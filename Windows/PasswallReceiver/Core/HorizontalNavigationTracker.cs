namespace PasswallReceiver.Core;

internal enum HorizontalNavigationAction
{
    Back,
    Forward
}

internal readonly record struct HorizontalNavigationResult(
    bool Consumed,
    HorizontalNavigationAction? Action);

internal sealed class HorizontalNavigationTracker
{
    private double distance;
    private bool active;
    private bool triggered;

    public HorizontalNavigationResult Update(
        double horizontal,
        double vertical,
        string phase)
    {
        if (phase == "began") Reset();
        if (phase.StartsWith("momentum_", StringComparison.Ordinal))
        {
            return new(Math.Abs(horizontal) > Math.Abs(vertical), null);
        }
        if (!active)
        {
            if (Math.Abs(horizontal) <= Math.Abs(vertical) || horizontal == 0)
            {
                return new(false, null);
            }
            active = true;
        }
        else if (Math.Abs(vertical) > Math.Abs(horizontal) * 1.5)
        {
            Reset();
            return new(false, null);
        }

        distance += horizontal;
        HorizontalNavigationAction? action = null;
        if (!triggered && Math.Abs(distance) >= 36)
        {
            triggered = true;
            action = distance > 0
                ? HorizontalNavigationAction.Back
                : HorizontalNavigationAction.Forward;
        }
        if (phase is "ended" or "cancelled") Reset();
        return new(true, action);
    }

    public void Reset()
    {
        distance = 0;
        active = false;
        triggered = false;
    }
}
