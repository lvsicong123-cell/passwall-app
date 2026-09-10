using System.ComponentModel;
using System.Runtime.InteropServices;

namespace PasswallReceiver.Core;

internal sealed class WindowsBonjourPublisher : IDisposable
{
    private const uint DnsRequestPending = 9506;
    private const uint Success = 0;

    private static readonly DnsServiceRegisterComplete CompletionCallback = OnNativeCallback;

    private readonly object gate = new();
    private readonly string instanceName;
    private GCHandle selfHandle;
    private IntPtr serviceInstance;
    private IntPtr request;
    private int callbackCount;
    private int disposeRequested;
    private bool cleanedUp;

    private WindowsBonjourPublisher(BonjourAdvertisement advertisement)
    {
        instanceName = advertisement.InstanceName;
        var properties = advertisement.Properties.OrderBy(pair => pair.Key).ToArray();
        var keys = AllocateStringArray(properties.Select(pair => pair.Key));
        var values = AllocateStringArray(properties.Select(pair => pair.Value));

        try
        {
            serviceInstance = DnsServiceConstructInstance(
                advertisement.InstanceName,
                Environment.MachineName,
                IntPtr.Zero,
                IntPtr.Zero,
                advertisement.Port,
                0,
                0,
                (uint)properties.Length,
                keys.Array,
                values.Array);
        }
        finally
        {
            FreeStringArray(keys);
            FreeStringArray(values);
        }

        if (serviceInstance == IntPtr.Zero)
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "DnsServiceConstructInstance failed");
        }

        selfHandle = GCHandle.Alloc(this);
        var nativeRequest = new DnsServiceRegisterRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            ServiceInstance = serviceInstance,
            CompletionCallback = Marshal.GetFunctionPointerForDelegate(CompletionCallback),
            QueryContext = GCHandle.ToIntPtr(selfHandle),
            Credentials = IntPtr.Zero,
            UnicastEnabled = 0
        };
        request = Marshal.AllocHGlobal(Marshal.SizeOf<DnsServiceRegisterRequest>());
        Marshal.StructureToPtr(nativeRequest, request, fDeleteOld: false);

        var status = DnsServiceRegister(request, IntPtr.Zero);
        if (status != DnsRequestPending)
        {
            CleanupNativeState();
            throw new Win32Exception(
                unchecked((int)status),
                $"Bonjour registration request failed with status {status}");
        }
    }

    public static WindowsBonjourPublisher Start(
        ushort port,
        string certificateFingerprint) =>
        new(BonjourAdvertisement.Create(
            Environment.MachineName,
            port,
            certificateFingerprint));

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposeRequested, 1) != 0) return;

        IntPtr requestToCancel;
        lock (gate)
        {
            requestToCancel = request;
        }
        if (requestToCancel == IntPtr.Zero) return;

        var status = DnsServiceDeRegister(requestToCancel, IntPtr.Zero);
        if (status == DnsRequestPending) return;

        Console.Error.WriteLine(
            $"Bonjour deregistration request failed with status {status}");
        CleanupNativeState();
    }

    private static void OnNativeCallback(
        uint status,
        IntPtr queryContext,
        IntPtr callbackInstance)
    {
        try
        {
            if (queryContext == IntPtr.Zero) return;
            var handle = GCHandle.FromIntPtr(queryContext);
            if (handle.Target is WindowsBonjourPublisher publisher)
            {
                publisher.HandleCompletion(status);
            }
        }
        finally
        {
            if (callbackInstance != IntPtr.Zero)
            {
                DnsServiceFreeInstance(callbackInstance);
            }
        }
    }

    private void HandleCompletion(uint status)
    {
        var completionNumber = Interlocked.Increment(ref callbackCount);
        if (completionNumber == 1)
        {
            if (status == Success)
            {
                Console.WriteLine($"Bonjour advertised {instanceName}");
            }
            else
            {
                Console.Error.WriteLine(
                    $"Bonjour registration failed with status {status}");
                CleanupNativeState();
            }
            return;
        }

        if (status != Success)
        {
            Console.Error.WriteLine(
                $"Bonjour deregistration failed with status {status}");
        }
        CleanupNativeState();
    }

    private void CleanupNativeState()
    {
        lock (gate)
        {
            if (cleanedUp) return;
            cleanedUp = true;

            if (request != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(request);
                request = IntPtr.Zero;
            }
            if (serviceInstance != IntPtr.Zero)
            {
                DnsServiceFreeInstance(serviceInstance);
                serviceInstance = IntPtr.Zero;
            }
            if (selfHandle.IsAllocated)
            {
                selfHandle.Free();
            }
        }
    }

    private static NativeStringArray AllocateStringArray(IEnumerable<string> values)
    {
        var strings = values
            .Select(Marshal.StringToHGlobalUni)
            .ToArray();
        if (strings.Length == 0)
        {
            return new NativeStringArray(IntPtr.Zero, strings);
        }

        var array = Marshal.AllocHGlobal(IntPtr.Size * strings.Length);
        for (var index = 0; index < strings.Length; index++)
        {
            Marshal.WriteIntPtr(array, index * IntPtr.Size, strings[index]);
        }
        return new NativeStringArray(array, strings);
    }

    private static void FreeStringArray(NativeStringArray array)
    {
        foreach (var value in array.Strings)
        {
            Marshal.FreeHGlobal(value);
        }
        if (array.Array != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(array.Array);
        }
    }

    private readonly record struct NativeStringArray(
        IntPtr Array,
        IReadOnlyList<IntPtr> Strings);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void DnsServiceRegisterComplete(
        uint status,
        IntPtr queryContext,
        IntPtr serviceInstance);

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceRegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr CompletionCallback;
        public IntPtr QueryContext;
        public IntPtr Credentials;
        public int UnicastEnabled;
    }

    [DllImport(
        "dnsapi.dll",
        CharSet = CharSet.Unicode,
        CallingConvention = CallingConvention.Winapi,
        SetLastError = true)]
    private static extern IntPtr DnsServiceConstructInstance(
        string serviceName,
        string hostName,
        IntPtr ip4Address,
        IntPtr ip6Address,
        ushort port,
        ushort priority,
        ushort weight,
        uint propertyCount,
        IntPtr keys,
        IntPtr values);

    [DllImport("dnsapi.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern uint DnsServiceRegister(
        IntPtr request,
        IntPtr cancel);

    [DllImport("dnsapi.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern uint DnsServiceDeRegister(
        IntPtr request,
        IntPtr cancel);

    [DllImport("dnsapi.dll", CallingConvention = CallingConvention.Winapi)]
    private static extern void DnsServiceFreeInstance(IntPtr serviceInstance);
}
