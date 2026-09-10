using System.ComponentModel;
using System.Runtime.InteropServices;

namespace PasswallReceiver.Core;

internal static class WindowsTrustedPeerStore
{
    private const uint GenericCredential = 1;
    private const uint PersistLocalMachine = 2;
    private const string TargetPrefix = "Passwall/TrustedMac/";

    public static void Save(string controllerID, byte[] secret)
    {
        if (secret.Length != 32)
        {
            throw new ArgumentException(
                "Trusted peer secret must be 32 bytes",
                nameof(secret));
        }

        var blob = Marshal.AllocHGlobal(secret.Length);
        try
        {
            Marshal.Copy(secret, 0, blob, secret.Length);
            var credential = new Credential
            {
                Type = GenericCredential,
                TargetName = TargetPrefix + controllerID,
                CredentialBlobSize = (uint)secret.Length,
                CredentialBlob = blob,
                Persist = PersistLocalMachine,
                UserName = controllerID
            };
            if (!CredWrite(ref credential, 0))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    public static byte[]? Load(string controllerID)
    {
        if (!CredRead(
                TargetPrefix + controllerID,
                GenericCredential,
                0,
                out var pointer))
        {
            const int NotFound = 1168;
            var error = Marshal.GetLastWin32Error();
            if (error == NotFound) return null;
            throw new Win32Exception(error);
        }

        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            var secret = new byte[credential.CredentialBlobSize];
            Marshal.Copy(
                credential.CredentialBlob,
                secret,
                0,
                secret.Length);
            return secret;
        }
        finally
        {
            CredFree(pointer);
        }
    }

    public static void Delete(string controllerID)
    {
        if (!CredDelete(
                TargetPrefix + controllerID,
                GenericCredential,
                0))
        {
            const int NotFound = 1168;
            var error = Marshal.GetLastWin32Error();
            if (error != NotFound)
            {
                throw new Win32Exception(error);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW",
        CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(
        ref Credential credential,
        uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW",
        CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(
        string target,
        uint type,
        uint flags,
        out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW",
        CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(
        string target,
        uint type,
        uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
