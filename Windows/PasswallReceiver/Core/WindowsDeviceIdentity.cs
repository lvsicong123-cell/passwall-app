using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace PasswallReceiver.Core;

internal sealed class WindowsDeviceIdentity : IDisposable
{
    private const string IdentityFriendlyName = "Passwall Receiver Identity";

    private WindowsDeviceIdentity(X509Certificate2 certificate)
    {
        Certificate = certificate;
        FingerprintHex = Fingerprint(certificate);
    }

    public X509Certificate2 Certificate { get; }
    public string FingerprintHex { get; }

    public static WindowsDeviceIdentity LoadOrCreate()
    {
        var now = DateTimeOffset.UtcNow;
        using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadWrite);

        var existing = store.Certificates
            .OfType<X509Certificate2>()
            .Where(certificate =>
                certificate.FriendlyName == IdentityFriendlyName &&
                certificate.HasPrivateKey &&
                certificate.NotAfter.ToUniversalTime() > now.AddDays(30))
            .OrderByDescending(certificate => certificate.NotAfter)
            .FirstOrDefault();
        if (existing is not null)
        {
            return new WindowsDeviceIdentity(existing);
        }

        var certificate = CreateCertificate(
            Environment.MachineName,
            now,
            persistPrivateKey: true);
        certificate.FriendlyName = IdentityFriendlyName;
        store.Add(certificate);
        return new WindowsDeviceIdentity(certificate);
    }

    internal static X509Certificate2 CreateCertificate(
        string machineName,
        DateTimeOffset now,
        bool persistPrivateKey = false)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest(
            $"CN=Passwall Receiver {machineName}",
            key,
            HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(
            new X509BasicConstraintsExtension(
                certificateAuthority: false,
                hasPathLengthConstraint: false,
                pathLengthConstraint: 0,
                critical: true));
        request.CertificateExtensions.Add(
            new X509KeyUsageExtension(
                X509KeyUsageFlags.DigitalSignature,
                critical: true));
        request.CertificateExtensions.Add(
            new X509EnhancedKeyUsageExtension(
                new OidCollection
                {
                    new("1.3.6.1.5.5.7.3.1", "TLS Web Server Authentication")
                },
                critical: true));

        var subjectAlternativeNames = new SubjectAlternativeNameBuilder();
        subjectAlternativeNames.AddDnsName(machineName);
        subjectAlternativeNames.AddDnsName($"{machineName}.local");
        request.CertificateExtensions.Add(subjectAlternativeNames.Build());

        using var generated = request.CreateSelfSigned(
            now.AddMinutes(-5),
            now.AddYears(5));
        var storage = X509KeyStorageFlags.UserKeySet;
        if (persistPrivateKey)
        {
            storage |= X509KeyStorageFlags.PersistKeySet;
        }
        return new X509Certificate2(
            generated.Export(X509ContentType.Pfx),
            (string?)null,
            storage);
    }

    public static string Fingerprint(X509Certificate certificate) =>
        Convert.ToHexString(SHA256.HashData(certificate.GetRawCertData()))
            .ToLowerInvariant();

    public void Dispose() => Certificate.Dispose();
}
