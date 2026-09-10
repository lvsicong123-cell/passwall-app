namespace PasswallReceiver.Core;

internal sealed class SessionMessageGuard
{
    private string? sessionID;

    public ulong LastAcceptedSequence { get; private set; }

    public void Accept(int version, string sessionID, ulong sequence)
    {
        if (version != ProtocolContract.Version)
        {
            throw new InvalidDataException($"Unsupported protocol version: {version}");
        }
        if (string.IsNullOrWhiteSpace(sessionID))
        {
            throw new InvalidDataException("Missing session ID");
        }
        if (this.sessionID is not null && this.sessionID != sessionID)
        {
            throw new InvalidDataException("Session ID changed on an active connection");
        }
        if (sequence <= LastAcceptedSequence)
        {
            throw new InvalidDataException(
                $"Message sequence {sequence} did not follow {LastAcceptedSequence}");
        }

        this.sessionID ??= sessionID;
        LastAcceptedSequence = sequence;
    }
}
