using System.Security.Cryptography;
using System.Text;

namespace PasswallReceiver.Core;

internal sealed class PairingChallenge
{
    public const int NonceByteCount = 16;
    private static readonly byte[] Context =
        Encoding.ASCII.GetBytes("passwall-pairing-v1");
    private readonly byte[] serverNonce;
    private readonly byte[] fingerprint;
    private bool confirmed;

    public PairingChallenge(
        string certificateFingerprint,
        byte[]? serverNonce = null)
    {
        fingerprint = Convert.FromHexString(certificateFingerprint);
        if (fingerprint.Length != 32)
        {
            throw new ArgumentException(
                "Certificate fingerprint must be SHA-256",
                nameof(certificateFingerprint));
        }

        this.serverNonce = serverNonce ?? RandomNumberGenerator.GetBytes(
            NonceByteCount);
        if (this.serverNonce.Length != NonceByteCount)
        {
            throw new ArgumentException(
                "Pairing nonce must be 16 bytes",
                nameof(serverNonce));
        }
        CommitmentHex = Convert.ToHexString(
            SHA256.HashData(this.serverNonce)).ToLowerInvariant();
    }

    public string CommitmentHex { get; }
    public string ServerNonceHex =>
        Convert.ToHexString(serverNonce).ToLowerInvariant();

    public string Complete(string clientNonceHex)
    {
        var digest = SHA256.HashData(Transcript(clientNonceHex));
        var value =
            ((uint)digest[0] << 24) |
            ((uint)digest[1] << 16) |
            ((uint)digest[2] << 8) |
            digest[3];
        return (value % 1_000_000).ToString("D6");
    }

    public void Confirm(
        string commitmentHex,
        string clientNonceHex,
        string controllerID,
        byte[] secret,
        string proofHex)
    {
        RejectReplay();
        if (!CryptographicOperations.FixedTimeEquals(
                Encoding.ASCII.GetBytes(CommitmentHex),
                Encoding.ASCII.GetBytes(commitmentHex.ToLowerInvariant())))
        {
            throw new InvalidDataException(
                "Pairing confirmation does not match this challenge");
        }
        var code = Complete(clientNonceHex);
        VerifyProof(
            Convert.FromHexString(ConfirmationProof(
                code,
                clientNonceHex,
                controllerID,
                secret)),
            proofHex);
        confirmed = true;
    }

    public void Resume(
        string clientNonceHex,
        string controllerID,
        byte[] secret,
        string proofHex)
    {
        RejectReplay();
        VerifyProof(
            Convert.FromHexString(ResumeProof(
                clientNonceHex,
                controllerID,
                secret)),
            proofHex);
        confirmed = true;
    }

    public string ConfirmationProof(
        string code,
        string clientNonceHex,
        string controllerID,
        byte[] secret)
    {
        byte[] payload = [
            .. Encoding.ASCII.GetBytes("passwall-confirm-v1"),
            .. Transcript(clientNonceHex),
            .. Encoding.ASCII.GetBytes(controllerID),
            .. secret
        ];
        return Convert.ToHexString(HMACSHA256.HashData(
            Encoding.ASCII.GetBytes(code),
            payload)).ToLowerInvariant();
    }

    public string ResumeProof(
        string clientNonceHex,
        string controllerID,
        byte[] secret)
    {
        byte[] payload = [
            .. Encoding.ASCII.GetBytes("passwall-resume-v1"),
            .. Transcript(clientNonceHex),
            .. Encoding.ASCII.GetBytes(controllerID)
        ];
        return Convert.ToHexString(HMACSHA256.HashData(
            secret,
            payload)).ToLowerInvariant();
    }

    private byte[] Transcript(string clientNonceHex)
    {
        var clientNonce = Convert.FromHexString(clientNonceHex);
        if (clientNonce.Length != NonceByteCount)
        {
            throw new InvalidDataException("Client nonce must be 16 bytes");
        }
        return [
            .. Context,
            .. fingerprint,
            .. serverNonce,
            .. clientNonce
        ];
    }

    private void RejectReplay()
    {
        if (confirmed)
        {
            throw new InvalidDataException("Pairing confirmation was replayed");
        }
    }

    private static void VerifyProof(byte[] expected, string proofHex)
    {
        byte[] actual;
        try
        {
            actual = Convert.FromHexString(proofHex);
        }
        catch (FormatException error)
        {
            throw new InvalidDataException(
                "Pairing proof is malformed",
                error);
        }
        if (!CryptographicOperations.FixedTimeEquals(expected, actual))
        {
            throw new InvalidDataException("Pairing proof did not match");
        }
    }
}
