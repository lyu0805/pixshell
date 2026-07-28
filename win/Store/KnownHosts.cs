using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using PixShell.Logging;

namespace PixShell;

/// <summary>
/// 主机指纹管理：读写 <c>%USERPROFILE%\.ssh\known_hosts</c>（对齐 mac Store/KnownHosts.swift）。
/// 指纹按 OpenSSH 规则：对 base64 解码后的公钥字节做 SHA256（无 padding base64）/ MD5（冒号 hex）。
/// </summary>
public static class KnownHosts
{
    public sealed class Entry
    {
        public string Hosts { get; init; } = "";
        public string KeyType { get; init; } = "";
        public string KeyTypeShort { get; init; } = "";
        public string FingerprintSHA256 { get; init; } = "";
        public string FingerprintMD5 { get; init; } = "";
        public string RawLine { get; init; } = "";
        public string? Marker { get; init; }
    }

    public static string Path => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "known_hosts");

    public static List<Entry> List()
    {
        var result = new List<Entry>();
        if (!File.Exists(Path)) return result;
        string text;
        try { text = File.ReadAllText(Path); }
        catch { return result; }

        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var e = Parse(line);
            if (e != null) result.Add(e);
        }
        return result;
    }

    /// <summary>删除一条指纹：按 RawLine 精确匹配后写回。</summary>
    public static void Delete(Entry entry)
    {
        if (!File.Exists(Path)) return;
        string text;
        try { text = File.ReadAllText(Path); }
        catch (Exception ex)
        {
            Log.Warn("读 known_hosts 失败: " + ex.Message, "known_hosts");
            return;
        }

        var target = entry.RawLine.Trim();
        var kept = text.Split('\n')
            .Where(l => l.Trim() != target)
            .ToList();
        var body = string.Join("\n", kept);
        if (body.Length > 0 && !body.EndsWith("\n", StringComparison.Ordinal))
            body += "\n";

        try
        {
            var dir = System.IO.Path.GetDirectoryName(Path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(Path, body, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            Log.Info($"删除主机指纹 {entry.Hosts} ({entry.KeyTypeShort})", "known_hosts");
        }
        catch (Exception ex)
        {
            Log.Warn("写 known_hosts 失败: " + ex.Message, "known_hosts");
        }
    }

    /// <summary>导出 known_hosts 原文到目标文件。</summary>
    public static int Export(string destPath)
    {
        var text = File.Exists(Path) ? File.ReadAllText(Path) : "";
        var dir = System.IO.Path.GetDirectoryName(destPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        File.WriteAllText(destPath, text, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        var count = List().Count;
        Log.Info($"导出主机指纹 {count} 条 → {destPath}", "known_hosts");
        return count;
    }

    public readonly record struct ImportResult(int Added, int SkippedDuplicate, int SkippedInvalid);

    /// <summary>
    /// 从 known_hosts 格式文本合并：跳过空行/注释，按 trim 后整行去重，追加新行。
    /// </summary>
    public static ImportResult ImportMerging(string sourcePath)
    {
        var incoming = File.ReadAllText(sourcePath);
        return ImportMergingText(incoming, System.IO.Path.GetFileName(sourcePath));
    }

    public static ImportResult ImportMergingText(string text, string source = "text")
    {
        var existingText = File.Exists(Path) ? File.ReadAllText(Path) : "";
        var existingLines = existingText.Split('\n').ToList();
        var existingKeys = new HashSet<string>(
            existingLines
                .Select(l => l.Trim())
                .Where(l => l.Length > 0 && !l.StartsWith('#')));

        var added = 0;
        var skippedDuplicate = 0;
        var skippedInvalid = 0;

        foreach (var raw in text.Split('\n'))
        {
            var trimmed = raw.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith('#')) continue;
            if (Parse(trimmed) == null)
            {
                skippedInvalid++;
                continue;
            }
            if (existingKeys.Contains(trimmed))
            {
                skippedDuplicate++;
                continue;
            }
            while (existingLines.Count > 0 && string.IsNullOrWhiteSpace(existingLines[^1]))
                existingLines.RemoveAt(existingLines.Count - 1);
            existingLines.Add(trimmed);
            existingKeys.Add(trimmed);
            added++;
        }

        if (added > 0)
        {
            var body = string.Join("\n", existingLines);
            if (body.Length > 0 && !body.EndsWith("\n", StringComparison.Ordinal))
                body += "\n";
            var dir = System.IO.Path.GetDirectoryName(Path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(Path, body, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }

        Log.Info($"导入主机指纹 {source}：新增 {added} / 重复 {skippedDuplicate} / 无效 {skippedInvalid}", "known_hosts");
        return new ImportResult(added, skippedDuplicate, skippedInvalid);
    }

    private static Entry? Parse(string line)
    {
        var tokens = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
        if (tokens.Count < 3) return null;

        string? marker = null;
        if (tokens[0].StartsWith('@'))
        {
            marker = tokens[0];
            tokens.RemoveAt(0);
            if (tokens.Count < 3) return null;
        }

        var hosts = tokens[0];
        var keyType = tokens[1];
        var b64 = tokens[2];
        byte[] keyData;
        try { keyData = Convert.FromBase64String(b64); }
        catch { return null; }

        return new Entry
        {
            Hosts = hosts,
            KeyType = keyType,
            KeyTypeShort = ShortType(keyType),
            FingerprintSHA256 = "SHA256:" + Base64NoPad(SHA256.HashData(keyData)),
            FingerprintMD5 = "MD5:" + Md5Colon(MD5.HashData(keyData)),
            RawLine = line,
            Marker = marker,
        };
    }

    private static string ShortType(string t)
    {
        var lower = t.ToLowerInvariant();
        if (lower.Contains("ed25519")) return "ED25519";
        if (lower.Contains("ecdsa")) return "ECDSA";
        if (lower.Contains("rsa")) return "RSA";
        if (lower.Contains("dss") || lower.Contains("dsa")) return "DSA";
        return t.ToUpperInvariant();
    }

    private static string Base64NoPad(byte[] hash) =>
        Convert.ToBase64String(hash).TrimEnd('=');

    private static string Md5Colon(byte[] hash) =>
        string.Join(":", hash.Select(b => b.ToString("x2")));
}
