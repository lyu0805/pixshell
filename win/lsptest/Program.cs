using System;
using System.Threading;

// LSPClient 单元验证：对齐 mac 的协议探测
class Program
{
    static void Main()
    {
        var ra = PixShell.LSP.LSPClient.Locate();
        Console.WriteLine("rust-analyzer: " + (ra ?? "未找到"));
        if (ra == null) return;

        var file = "C:\\PixShell-all\\win\\lsptest\\main.rs";
        var text = System.IO.File.ReadAllText(file);
        var client = new PixShell.LSP.LSPClient();
        var ready = false;
        var diags = new System.Collections.Generic.List<PixShell.LSP.LSPClient.Diagnostic>();
        var done = new ManualResetEventSlim(false);

        client.ReadyChanged += ok => { ready = ok; Console.WriteLine("ReadyChanged: " + ok); };
        client.Diagnostics += list => {
            diags = list;
            Console.WriteLine($"Diagnostics: {list.Count} 条");
            foreach (var d in list) Console.WriteLine($"  sev={(d.IsError ? "ERR" : "WARN")} {d.Message}");
        };

        client.Start("C:\\PixShell-all\\win\\lsptest", "file:///" + file.Replace('\\', '/'), text);

        // 等就绪 + 诊断
        var t0 = DateTime.Now;
        while ((!ready || diags.Count == 0) && (DateTime.Now - t0).TotalSeconds < 40)
        {
            Thread.Sleep(300);
        }
        Console.WriteLine($"ready={ready} diags={diags.Count}");

        // 等分析稳定（诊断非空后多等几秒，避免 -32801 content modified）
        while (diags.Count == 0 && (DateTime.Now - t0).TotalSeconds < 60) Thread.Sleep(300);
        Thread.Sleep(5000);

        // hover
        client.HoverAsync("file:///" + file.Replace('\\', '/'), 0, 4, v =>
            Console.WriteLine($"hover: {(string.IsNullOrEmpty(v) ? "空" : v.Substring(0, Math.Min(50, v.Length)))}"));

        // completion
        client.CompletionAsync("file:///" + file.Replace('\\', '/'), 1, 8, items =>
            Console.WriteLine($"completion: {items.Count} 条, 前3: {string.Join(",", items.ConvertAll(i => i.Label).GetRange(0, Math.Min(3, items.Count)))}"));

        // definition
        client.DefinitionAsync("file:///" + file.Replace('\\', '/'), 0, 5, pos =>
            Console.WriteLine($"definition: {(pos.HasValue ? $"L{pos.Value.Line + 1}:{pos.Value.Char}" : "空")}"));

        Thread.Sleep(6000);
        client.Dispose();
        Console.WriteLine("=== win LSPClient 验证完成 ===");
    }
}
