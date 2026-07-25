/**
 * Map an external JSON settings document into PixShell settings shape.
 * node scripts/import-config.js [config.json]
 */
const fs = require('fs')
const path = require('path')
const os = require('os')

function mapConfig(raw) {
  const layout = raw.layout || {}
  const ci = raw.command_input || {}
  return {
    theme: raw.theme === 'Default' ? 'pixel-retro' : raw.theme || 'pixel-retro',
    enFontName: raw.en_font_name,
    cnFontName: raw.cn_font_name,
    fontSize: raw.font_size,
    showSidebar: raw.show_sidebar,
    bgImgEnable: raw.bg_img_enable,
    bgImg: raw.bg_img,
    bgImgBlurLevel: raw.bg_img_blur_level,
    closeToTray: raw.close_to_tray,
    confirmClose: raw.confirm_close,
    closeWindowAfterConnect: raw.close_window_after_connect,
    packTrans: raw.pack_trans,
    commandInput: {
      cleanAfterSend: !!ci.clean_after_send_command,
      ignoreBlankLine: !!ci.ignore_blankl_line,
      appendCr: !!ci.append_cr,
      sendCommandKey: ci.send_command_key ?? 1,
      show: !raw.command_input_show_hide,
      promptEnable: !!raw.command_prompt_enable,
      fullPath: !!raw.command_input_full_path,
      cacheExpireTime: raw.command_input_cache_expire_time ?? 3,
    },
    layout: {
      leftSideWidth: layout.left_side_width ?? 200,
      leftSideBottomHeight: layout.left_side_bottom_height ?? 140,
      centerBottomHeight: layout.center_bottom_height ?? 220,
      commandDividerLocation: layout.command_divider_location ?? 600,
      window: {
        x: layout.window_bounds_x ?? 80,
        y: layout.window_bounds_y ?? 60,
        width: layout.window_bounds_width ?? 1280,
        height: layout.window_bounds_height ?? 800,
        maximized: !!layout.window_maxmized,
      },
      tabLayouts: raw.layout_config || {},
    },
    quickCommands: raw.quick_commands || [],
    selectedCmdGroup: raw.selected_cmd_group || '',
    cmdHistory: raw.cmd_history || [],
    proxyList: raw.proxy_list || [],
    downloadPath: raw.download_path,
    hotkeys2: raw.hotkeys2 || {},
    syncConfig: raw.sync_config || {},
    accelerate: {
      enabled: false,
      protocol: 'udp',
      server_port: 150,
      direct_cn: true,
      server_host: '',
      interoperable: false,
      note: 'custom accelerate relay; not a generic open protocol',
    },
  }
}

function main() {
  const input = process.argv[2] || process.env.PIXSHELL_IMPORT_CONFIG_JSON || ''
  if (!input) {
    console.error('Usage: node scripts/import-config.js <config.json>')
    process.exit(1)
  }
  const raw = JSON.parse(fs.readFileSync(input, 'utf8'))
  const mapped = mapConfig(raw)
  const out = process.argv[3] || path.join(os.tmpdir(), 'pixshell-imported-settings.json')
  fs.mkdirSync(path.dirname(out), { recursive: true })
  fs.writeFileSync(out, JSON.stringify({ source: input, settings: mapped }, null, 2))
  console.log('mapped settings ->', out)
  return mapped
}

if (require.main === module) main()
module.exports = { mapConfig, main }
