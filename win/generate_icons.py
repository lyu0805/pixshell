from pathlib import Path
import glob
import os
import re

root = Path(__file__).resolve().parents[1]
assets_dir = root / "mac" / "Sources" / "PixShell" / "Resources" / "Assets.xcassets"
output_file = Path(__file__).resolve().parent / "UI" / "OsIcons.cs"

out = """using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows;
using System.Collections.Generic;

namespace PixShell.UI;

public static class OsIcons
{
    private static Geometry Parse(string data) => Geometry.Parse(data);
    
    public static Path GetIcon(string osId)
    {
        string pathData = "";
        string colorHex = "#888888";
        
        switch (osId?.ToLower())
        {
"""

for svg_file in glob.glob(str(assets_dir / "**" / "*.svg"), recursive=True):
    name = os.path.basename(svg_file).replace('.svg', '').replace('os-', '')
    with open(svg_file, 'r', encoding='utf-8') as f:
        content = f.read()
        m = re.search(r'd="([^"]+)"', content)
        if m:
            path = m.group(1)
            color = "#888888"
            if name in ['ubuntu', 'debian']: color = "#E95420"
            elif name in ['centos', 'fedora', 'linux']: color = "#294172"
            elif name == 'rhel': color = "#CC0000"
            elif name in ['alpine', 'openwrt']: color = "#0D597F"
            elif name == 'windows': color = "#0078D6"
            elif name == 'mac': color = "#555555"
            elif name == 'arch': color = "#1793D1"
            elif name == 'suse': color = "#73BA25"
            
            out += f'            case "{name}":\n'
            out += f'                pathData = "{path}";\n'
            out += f'                colorHex = "{color}";\n'
            out += '                break;\n'

out += """            default:
                pathData = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"; // fallback info icon
                colorHex = "#888888";
                break;
        }
        
        var path = new Path
        {
            Data = Parse(pathData),
            Fill = new SolidColorBrush((Color)ColorConverter.ConvertFromString(colorHex)),
            Stretch = Stretch.Uniform,
            Width = 20,
            Height = 20,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        return path;
    }
}
"""

output_file.parent.mkdir(parents=True, exist_ok=True)
output_file.write_text(out, encoding='utf-8')
