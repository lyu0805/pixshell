using System;
using System.Threading.Tasks;

namespace PixShell.Transports;

public interface ITerminalTransport : IDisposable
{
    bool Connected { get; }
    
    event Action<string>? Base64DataReceived;
    event Action<string>? TextReceived;
    event Action<string>? StatusChanged;
    event Action<bool>? ConnectedChanged;

    Task ConnectAsync();
    void Write(byte[] data);
    void Resize(uint cols, uint rows);
    void Disconnect();
    Task<string> ExecAsync(string command);
}

internal static class TransportHelper
{
    public static void ExtractIncompleteANSI(string text, out string complete, out string incomplete)
    {
        int maxLookback = Math.Min(text.Length, 2048);
        for (int i = text.Length - 1; i >= text.Length - maxLookback; i--)
        {
            if (text[i] == '\x1B')
            {
                if (i + 1 >= text.Length)
                {
                    complete = text.Substring(0, i);
                    incomplete = text.Substring(i);
                    return;
                }
                char next = text[i + 1];
                if (next == '[')
                {
                    bool isComplete = false;
                    for (int j = i + 2; j < text.Length; j++)
                    {
                        if (text[j] >= 0x40 && text[j] <= 0x7E)
                        {
                            isComplete = true;
                            break;
                        }
                    }
                    if (!isComplete)
                    {
                        complete = text.Substring(0, i);
                        incomplete = text.Substring(i);
                        return;
                    }
                }
                else if (next == ']')
                {
                    bool isComplete = false;
                    for (int j = i + 2; j < text.Length; j++)
                    {
                        if (text[j] == 0x07)
                        {
                            isComplete = true;
                            break;
                        }
                        if (text[j] == '\x1B' && j + 1 < text.Length && text[j + 1] == '\\')
                        {
                            isComplete = true;
                            break;
                        }
                    }
                    if (!isComplete)
                    {
                        complete = text.Substring(0, i);
                        incomplete = text.Substring(i);
                        return;
                    }
                }
                else if (next == '(' || next == ')')
                {
                    if (i + 2 >= text.Length)
                    {
                        complete = text.Substring(0, i);
                        incomplete = text.Substring(i);
                        return;
                    }
                }
                break;
            }
        }
        complete = text;
        incomplete = "";
    }
}
