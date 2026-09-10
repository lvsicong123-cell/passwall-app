namespace PasswallReceiver.Core;

internal enum DesktopEdge
{
    Top,
    Right,
    Bottom,
    Left
}

internal readonly record struct VirtualDesktopBounds(int Left, int Top, int Width, int Height)
{
    internal int Right => Left + Math.Max(Width - 1, 0);
    internal int Bottom => Top + Math.Max(Height - 1, 0);
}

internal sealed class RemoteReturnDetector
{
    private const int EdgeTolerance = 1;

    private DesktopEdge edge;
    private double requiredDistance;
    private double accumulatedOutwardDistance;

    internal bool IsActive { get; private set; }

    internal static DesktopEdge ReturnEdgeFor(string remotePosition) => remotePosition switch
    {
        "top" => DesktopEdge.Bottom,
        "right" => DesktopEdge.Left,
        "bottom" => DesktopEdge.Top,
        "left" => DesktopEdge.Right,
        _ => throw new InvalidDataException($"Unknown remote position: {remotePosition}")
    };

    internal void Activate(DesktopEdge returnEdge, double activationDistance)
    {
        edge = returnEdge;
        requiredDistance = Math.Max(activationDistance, 1);
        accumulatedOutwardDistance = 0;
        IsActive = true;
    }

    internal double? Update(
        int x,
        int y,
        VirtualDesktopBounds bounds,
        double dx,
        double dy)
    {
        if (!IsActive || bounds.Width <= 0 || bounds.Height <= 0)
        {
            return null;
        }

        var outward = edge switch
        {
            DesktopEdge.Top => -dy,
            DesktopEdge.Right => dx,
            DesktopEdge.Bottom => dy,
            DesktopEdge.Left => -dx,
            _ => 0
        };
        var atEdge = edge switch
        {
            DesktopEdge.Top => y <= bounds.Top + EdgeTolerance,
            DesktopEdge.Right => x >= bounds.Right - EdgeTolerance,
            DesktopEdge.Bottom => y >= bounds.Bottom - EdgeTolerance,
            DesktopEdge.Left => x <= bounds.Left + EdgeTolerance,
            _ => false
        };

        if (!atEdge || outward <= 0)
        {
            accumulatedOutwardDistance = 0;
            return null;
        }

        accumulatedOutwardDistance += outward;
        if (accumulatedOutwardDistance < requiredDistance)
        {
            return null;
        }

        IsActive = false;
        accumulatedOutwardDistance = 0;
        var fraction = edge is DesktopEdge.Top or DesktopEdge.Bottom
            ? (x - bounds.Left) / (double)Math.Max(bounds.Width - 1, 1)
            : (y - bounds.Top) / (double)Math.Max(bounds.Height - 1, 1);
        return Math.Clamp(fraction, 0, 1);
    }

    internal void Reset()
    {
        IsActive = false;
        accumulatedOutwardDistance = 0;
    }
}
