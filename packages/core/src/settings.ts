/** App domain models */

export type HostAuthType = 'password' | 'key' | 'keyboard-interactive'

export interface HostProxyRef {
  id: string
  name: string
}

export interface HostProfile {
  id: string
  name: string
  host: string
  port: number
  username: string
  authType: HostAuthType
  /** encrypted or secret-store ref — never plain in logs */
  passwordRef?: string
  privateKeyRef?: string
  group?: string
  remark?: string
  proxyId?: string
  color?: string
  /** Optional raw import payload passthrough */
  raw?: Record<string, unknown>
}

export interface QuickCommand {
  id: string
  name: string
  group: string
  /** may contain ${param} placeholders */
  command: string
  params?: Array<{ name: string; defaultValue?: string; required?: boolean }>
}

export interface CommandInputSettings {
  cleanAfterSend: boolean
  ignoreBlankLine: boolean
  appendCr: boolean
  sendCommandKey: number
  show: boolean
  promptEnable: boolean
  fullPath: boolean
  cacheExpireTime: number
}

export interface LayoutState {
  leftSideWidth: number
  leftSideBottomHeight: number
  centerBottomHeight: number
  commandDividerLocation: number
  window: {
    x: number
    y: number
    width: number
    height: number
    maximized: boolean
  }
  tabLayouts: Record<
    string,
    {
      bottomHeight: number
      bottomVisible: boolean
    }
  >
}

export interface AppSettings {
  theme: string
  enFontName: string
  cnFontName: string
  fontSize: number
  showSidebar: boolean
  bgImgEnable: boolean
  bgImg: string
  bgImgBlurLevel: number
  closeToTray: boolean
  confirmClose: boolean
  closeWindowAfterConnect: boolean
  packTrans: boolean
  commandInput: CommandInputSettings
  layout: LayoutState
  proxyList: HostProxyRef[]
  quickCommands: QuickCommand[]
  selectedCmdGroup: string
  cmdHistory: string[]
}

export const defaultSettings = (): AppSettings => ({
  theme: 'pixel-retro',
  enFontName: 'DejaVuSansMono.ttf',
  cnFontName: 'Microsoft YaHei UI',
  fontSize: 12,
  showSidebar: true,
  bgImgEnable: false,
  bgImg: '',
  bgImgBlurLevel: 4,
  closeToTray: false,
  confirmClose: true,
  closeWindowAfterConnect: true,
  packTrans: false,
  commandInput: {
    cleanAfterSend: true,
    ignoreBlankLine: true,
    appendCr: true,
    sendCommandKey: 1,
    show: true,
    promptEnable: true,
    fullPath: true,
    cacheExpireTime: 3,
  },
  layout: {
    leftSideWidth: 200,
    leftSideBottomHeight: 140,
    centerBottomHeight: 220,
    commandDividerLocation: 600,
    window: { x: 80, y: 60, width: 1280, height: 800, maximized: false },
    tabLayouts: {
      tab_terminal: { bottomHeight: 220, bottomVisible: true },
      tab_tasktab: { bottomHeight: 300, bottomVisible: true },
      tab_host_detect_tab: { bottomHeight: 300, bottomVisible: true },
      tab_net_mananagertab: { bottomHeight: 300, bottomVisible: true },
    },
  },
  proxyList: [],
  quickCommands: [],
  selectedCmdGroup: '',
  cmdHistory: [],
})

/** Map external config.json subset → AppSettings */
export function mapLegacyConfig(raw: Record<string, any>): Partial<AppSettings> {
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
  }
}
