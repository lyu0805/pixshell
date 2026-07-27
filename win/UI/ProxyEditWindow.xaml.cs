using System.Windows;
using System.Windows.Controls;
using PixShell.Proxy;

namespace PixShell.UI;

/// <summary>
/// 新建/编辑代理表单，字段/网格布局照抄 HostEditWindow。
/// 类型选择只暴露 socks5/socks4/http 三种——ssh-jump(跳板机)本版本未实现真正逻辑，不提供入口新建；
/// 已存在的老 ssh-jump 配置进来编辑时默认落到 socks5，需要用户重新选择类型再保存（对齐 mac ProxyFormView）。
/// </summary>
public partial class ProxyEditWindow : Window
{
    private static readonly ProxyType[] SupportedTypes = { ProxyType.Socks5, ProxyType.Socks4, ProxyType.Http };

    public ProxyConfig Result { get; private set; }

    public ProxyEditWindow(ProxyConfig? existing)
    {
        InitializeComponent();
        Result = existing == null ? new ProxyConfig() : new ProxyConfig
        {
            Id = existing.Id, Name = existing.Name, Type = existing.Type, Host = existing.Host,
            Port = existing.Port, Username = existing.Username, Password = existing.Password,
        };

        NameBox.Text = Result.Name;
        var idx = System.Array.IndexOf(SupportedTypes, Result.Type);
        TypeBox.SelectedIndex = idx >= 0 ? idx : 0;
        HostBox.Text = Result.Host;
        PortBox.Text = Result.Port.ToString();
        UserBox.Text = Result.Username;
        PassBox.Password = Result.Password;
        Title = existing == null ? "新建代理" : "编辑代理";
    }

    /// <summary>切换类型时，若端口为空/非法则联动填入新类型默认端口；已手填的合法端口不覆盖。</summary>
    private void OnTypeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        var type = CurrentType();
        if (!int.TryParse(PortBox.Text.Trim(), out var cur) || cur <= 0)
            PortBox.Text = ProxyConfig.DefaultPort(type).ToString();
    }

    private ProxyType CurrentType()
    {
        var i = TypeBox.SelectedIndex;
        return (i >= 0 && i < SupportedTypes.Length) ? SupportedTypes[i] : ProxyType.Socks5;
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var type = CurrentType();
        Result.Name = string.IsNullOrWhiteSpace(NameBox.Text) ? "proxy" : NameBox.Text.Trim();
        Result.Type = type;
        Result.Host = HostBox.Text.Trim();
        Result.Port = int.TryParse(PortBox.Text.Trim(), out var port) && port > 0 ? port : ProxyConfig.DefaultPort(type);
        Result.Username = UserBox.Text.Trim();
        Result.Password = PassBox.Password;
        DialogResult = true;
    }
}
