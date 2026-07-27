using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using PixShell.Proxy;

namespace PixShell;

/// <summary>
/// 新建/编辑主机对话框。返回 DialogResult=true 时，Entry 为编辑后的主机，
/// Password 为用户填写的明文密码（由调用方决定是否用 DPAPI 落盘）。
/// 密码框留空表示「保持原密码不变」（编辑场景）或「不设密码」（新建场景）。
/// </summary>
public partial class HostEditWindow : Window
{
    public HostEntry Entry { get; private set; }

    /// <summary>用户新填写的密码；为 null 表示未改动，保留原有 DPAPI 凭据。</summary>
    public string? Password { get; private set; }

    public HostEditWindow(HostEntry? existing)
    {
        InitializeComponent();
        // 编辑已有主机则克隆，避免直接改动列表引用；新建则给一个空条目。
        Entry = existing == null
            ? new HostEntry()
            : new HostEntry
            {
                Id = existing.Id,
                Name = existing.Name,
                Host = existing.Host,
                Port = existing.Port,
                Username = existing.Username,
                Group = existing.Group,
                OsId = existing.OsId,
                KeyPath = existing.KeyPath,
                ProxyId = existing.ProxyId,
                ConnectionType = existing.ConnectionType
            };

        TypeBox.SelectedIndex = Entry.IsRdp ? 1 : 0;
        NameBox.Text = Entry.Name;
        HostBox.Text = Entry.Host;
        PortBox.Text = Entry.Port.ToString();
        UserBox.Text = Entry.Username;
        GroupBox.Text = string.IsNullOrWhiteSpace(Entry.Group) ? "默认" : Entry.Group;
        OsBox.Text = Entry.OsId;
        KeyPathBox.Text = Entry.KeyPath;
        Title = existing == null ? "新建主机" : "编辑主机";

        // 代理下拉：第一项固定"无"(id=空)，之后是 proxies.json 里的全部代理，按 Entry.ProxyId 预选。
        ProxyBox.Items.Add(new ComboBoxItem { Content = "无（直连）", Tag = "" });
        foreach (var p in ProxyStore.List())
            ProxyBox.Items.Add(new ComboBoxItem { Content = $"{(string.IsNullOrEmpty(p.Name) ? p.Host : p.Name)} ({p.DisplayName})", Tag = p.Id });
        var sel = ProxyBox.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == Entry.ProxyId);
        ProxyBox.SelectedItem = sel ?? ProxyBox.Items[0];
    }

    /// <summary>私钥文件选择：只选文件、显示隐藏文件（否则 %USERPROFILE%\.ssh 这类点开头目录默认不可见）。</summary>
    private void OnChooseKeyFile(object sender, RoutedEventArgs e)
    {
        var sshDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");
        var dlg = new OpenFileDialog
        {
            Title = "选择私钥文件",
            InitialDirectory = Directory.Exists(sshDir) ? sshDir : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Multiselect = false,
            CheckFileExists = true,
        };
        if (dlg.ShowDialog(this) == true) KeyPathBox.Text = dlg.FileName;
    }

    /// <summary>切到 RDP 且端口还是 SSH 默认 22 → 顺手改成 3389；切回 SSH 且端口是 3389 → 改回 22。</summary>
    private void OnTypeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (PortBox == null) return;   // 构造期 SelectedIndex 赋值会先触发一次，控件尚未就绪
        var p = PortBox.Text.Trim();
        if (TypeBox.SelectedIndex == 1 && p == "22") PortBox.Text = "3389";
        else if (TypeBox.SelectedIndex == 0 && p == "3389") PortBox.Text = "22";
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var host = HostBox.Text.Trim();
        var user = UserBox.Text.Trim();
        if (host.Length == 0 || user.Length == 0)
        {
            MessageBox.Show(this, "主机和用户名不能为空。", "PixShell",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (!int.TryParse(PortBox.Text.Trim(), out var port) || port <= 0 || port > 65535)
            port = 22;

        Entry.Name = NameBox.Text.Trim();
        Entry.Host = host;
        Entry.Port = port;
        Entry.Username = user;
        Entry.Group = string.IsNullOrWhiteSpace(GroupBox.Text) ? "默认" : GroupBox.Text.Trim();
        Entry.OsId = OsBox.Text.Trim();
        Entry.KeyPath = KeyPathBox.Text.Trim();
        Entry.ProxyId = (ProxyBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "";
        Entry.ConnectionType = TypeBox.SelectedIndex == 1 ? 200 : 100;

        // 密码框有内容才回传（空 = 不改动已存凭据）。
        Password = PassBox.Password.Length > 0 ? PassBox.Password : null;

        DialogResult = true;
    }
}
