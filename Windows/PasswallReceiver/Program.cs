using System.Text;

namespace PasswallReceiver;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        using var singleInstance = new Mutex(
            initiallyOwned: true,
            name: @"Local\PasswallReceiver",
            createdNew: out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show(
                "Passwall Receiver is already running.",
                "Passwall Receiver",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        var port = args.Length > 0 && ushort.TryParse(args[0], out var parsedPort)
            ? parsedPort
            : ReceiverRuntime.DefaultPort;
        var dataDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Passwall");
        Directory.CreateDirectory(dataDirectory);
        var logPath = Path.Combine(dataDirectory, "receiver.log");

        using var logStream = new FileStream(
            logPath,
            FileMode.Append,
            FileAccess.Write,
            FileShare.ReadWrite);
        using var log = TextWriter.Synchronized(new StreamWriter(
            logStream,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false))
        {
            AutoFlush = true
        });
        Console.SetOut(log);
        Console.SetError(log);
        Console.WriteLine($"--- Passwall Receiver started {DateTimeOffset.Now:O} ---");

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var context = new ReceiverApplicationContext(
            port,
            dataDirectory,
            logPath,
            openAtLaunch: args.Contains("--open", StringComparer.Ordinal));
        Application.Run(context);
    }
}
