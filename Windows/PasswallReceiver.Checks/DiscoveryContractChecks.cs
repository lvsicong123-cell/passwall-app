using PasswallReceiver.Core;

internal static class DiscoveryContractChecks
{
    public static int Run()
    {
        var checks = 0;
        var fingerprint = string.Concat(Enumerable.Repeat("a1", 32));
        var advertisement = BonjourAdvertisement.Create("Receiver.PC", 24871, fingerprint);

        Check(
            advertisement.InstanceName == "Receiver-PC._passwall._tcp.local",
            "Bonjour instance name was not normalized");
        Check(advertisement.Port == 24871, "Bonjour advertisement changed the pairing port");
        Check(advertisement.Properties.Count == 5, "Bonjour advertisement exposed unexpected metadata");
        Check(advertisement.Properties["pv"] == "3", "Bonjour protocol version is missing");
        Check(advertisement.Properties["role"] == "receiver", "Bonjour role is missing");
        Check(advertisement.Properties["pairing"] == "required", "Bonjour pairing state is missing");
        Check(advertisement.Properties["tls"] == "1.3", "Bonjour TLS version is missing");
        Check(advertisement.Properties["fp"] == fingerprint, "Bonjour certificate fingerprint is missing");

        return checks;

        void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
            checks++;
        }
    }
}
