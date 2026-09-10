namespace PasswallReceiver.Core;

internal sealed record BonjourAdvertisement(
    string InstanceName,
    ushort Port,
    IReadOnlyDictionary<string, string> Properties)
{
    public const string ServiceType = "_passwall._tcp";

    public static BonjourAdvertisement Create(
        string machineName,
        ushort port,
        string certificateFingerprint)
    {
        var label = NormalizeLabel(machineName);
        return new BonjourAdvertisement(
            $"{label}.{ServiceType}.local",
            port,
            new Dictionary<string, string>
            {
                ["pv"] = ProtocolContract.Version.ToString(),
                ["role"] = "receiver",
                ["pairing"] = "required",
                ["tls"] = "1.3",
                ["fp"] = certificateFingerprint
            });
    }

    private static string NormalizeLabel(string machineName)
    {
        var characters = machineName
            .Select(character =>
                character is >= 'A' and <= 'Z' or
                    >= 'a' and <= 'z' or
                    >= '0' and <= '9' or '-'
                    ? character
                    : '-')
            .ToArray();
        var label = new string(characters).Trim('-');
        if (label.Length == 0) label = "Windows-PC";
        if (label.Length > 63) label = label[..63].TrimEnd('-');
        return label;
    }
}
