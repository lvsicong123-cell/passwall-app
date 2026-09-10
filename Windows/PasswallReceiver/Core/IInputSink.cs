namespace PasswallReceiver.Core;

internal interface IInputSink
{
    double? Move(double dx, double dy, double gain);
    void EnterRemote(string remotePosition, double entryFraction, double activationDistance);
    void Warp(double x, double y);
    void Scroll(double horizontal, double vertical, string phase, bool navigationEnabled, double gain);
    void Button(string button, bool isDown);
    void Key(ushort usbHidUsage, bool isDown);
    void ReleaseAll();
}
