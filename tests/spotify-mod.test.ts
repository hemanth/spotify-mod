import { expect, mock, test } from 'claude-code/testing'
import {
  extractSpotifyTarget,
  normalizeControllerMode,
  normalizePosition,
} from '../hooks/register.js'

const PANE_SITE = {
  plugin: 'spotify-mod',
  component: 'Pane',
  requestId: 'spotify-mod',
  viewport: { columns: 110, rows: 36 },
  props: {
    title: 'Spotify',
    isFocused: true,
    bodyColumns: 38,
    placement: 'inline',
    scroll: { offset: 0, bodyRows: 24 },
    view: {},
  },
} as const

const ABOVE_PROMPT_SITE = {
  plugin: 'spotify-mod',
  component: 'AbovePrompt',
  surface: 'terminal',
  viewport: { columns: 110, rows: 36 },
  props: {},
} as const

function registerCommonStubs(
  on: any,
  processCalls: string[][] = [],
  toasts: string[] = [],
  openedPanes: string[] = [],
  closedPanes: string[] = [],
  processRun?: (e: any) => { exitCode: number; stdout: string; stderr: string },
) {
  mock.store(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal', TERM: 'xterm-256color' })
  mock.clock(on)
  on('session.start', () => ({ cwd: '/work' }))
  on('classic.SessionStart', () => ({}))
  on('command.register', () => ({ value: undefined }))
  on('tool.register', () => ({ value: undefined }))
  on('ui.open', (_$: any, e: any) => {
    openedPanes.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_$: any, e: any) => {
    closedPanes.push(e.id)
    return { value: undefined }
  })
  on('ui.toast', (_$: any, e: any) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('fs.read', () => ({ value: '' }))
  on('http.fetch', () => ({
    value: {
      status: 200,
      ok: true,
      headers: {},
      text: JSON.stringify({
        title: 'Veridis Quo',
        author_name: 'Daft Punk',
      }),
    },
  }))
  on('process.run', (_$: any, e: any) => {
    processCalls.push(e.argv)
    if (processRun) return { value: processRun(e) }
    return {
      value: {
        exitCode: 0,
        stdout: JSON.stringify({ lastVoiceQuery: 'daft punk veridis quo' }),
        stderr: '',
      },
    }
  })
  on('ui.render', () => ({
    type: 'Text',
    props: {},
    children: ['drawn by Claude Code'],
  }))
}

test('extractSpotifyTarget, normalizeControllerMode, and normalizePosition parse URLs, URIs, and modes', () => {
  expect(extractSpotifyTarget('4cOdK2wGLETKBW3PvgPWqT')?.id).toBe('4cOdK2wGLETKBW3PvgPWqT')
  expect(
    extractSpotifyTarget('https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b?si=1234')?.id,
  ).toBe('0VjIjW4GlUZAMYd2vXMi3b')
  expect(
    extractSpotifyTarget('https://open.spotify.com/playlist/37i9dQZF1DWWQRwui0ExPn')?.kind,
  ).toBe('playlist')
  expect(extractSpotifyTarget('spotify:track:5ChkMS8OtdzJeqyybCc9R5')?.id).toBe(
    '5ChkMS8OtdzJeqyybCc9R5',
  )
  expect(extractSpotifyTarget('lofi coding beats')).toBeNull()

  expect(normalizeControllerMode('tiny')).toBe('mini')
  expect(normalizeControllerMode('pull-panel')).toBe('side-panel')
  expect(normalizeControllerMode('side-panel')).toBe('side-panel')
  expect(normalizeControllerMode('popup')).toBe('popup')
  expect(normalizeControllerMode('card')).toBe('popup')

  expect(normalizePosition('pull-right')).toBe('right-side')
  expect(normalizePosition('pull-left')).toBe('left-side')
  expect(normalizePosition('tr')).toBe('top-right')
  expect(normalizePosition('1040,40,340,110')).toBe('custom')
})

test('/spotify defaults to inline Mini status bar (no popout) and switches cleanly between Sidebar and Popup', async ($, on) => {
  const processCalls: string[][] = []
  const toasts: string[] = []
  const openedPanes: string[] = []
  const closedPanes: string[] = []
  registerCommonStubs(on, processCalls, toasts, openedPanes, closedPanes)

  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await $.command.run({ command: 'spotify', args: '4cOdK2wGLETKBW3PvgPWqT' })

  // Nothing pops out in mini mode (no Pane opened)
  expect(openedPanes.length).toBe(0)
  expect(toasts.length).toBe(1)
  expect(toasts[0]).toContain('Veridis Quo')
  expect(processCalls.some((argv) => argv.includes('play') && argv.includes('mini'))).toBe(true)

  // Verify inline Mini Status Bar renders above prompt with Play, Pause, inline Search, and Voice
  const band = await $.ui.mount(ABOVE_PROMPT_SITE)
  expect(await band.find({ type: 'Text', text: /SPOTIFY \[MINI\]/ })).toBeDefined()
  expect(await band.find({ type: 'Button', key: 'mini-toggle-play' })).toBeDefined()
  expect(await band.find({ type: 'Button', key: 'mini-pause' })).toBeDefined()
  expect(await band.find({ type: 'Input', key: 'mini-search-input' })).toBeDefined()

  // Inline search directly inside the mini status bar without popping out a pane
  await band.input({ key: 'mini-search-input', text: '0VjIjW4GlUZAMYd2vXMi3b' })
  expect(openedPanes.length).toBe(0)

  // Clicking Sidebar opens ONLY the Claude Code sidebar pane (side-panel mode)
  await band.press({ key: 'mini-toggle-drawer' })
  expect(openedPanes).toContain('spotify-mod')
  expect(await band.find({ type: 'Text', text: /SPOTIFY \[SIDEBAR\]/ })).toBeDefined()

  // Clicking Popup switches to popup mode and closes the sidebar pane so both never show together
  await band.press({ key: 'mini-toggle-popup' })
  expect(closedPanes).toContain('spotify-mod')
  expect(await band.find({ type: 'Text', text: /SPOTIFY \[POPUP\]/ })).toBeDefined()
  await band.unmount()

  // Verify minimal Sidebar renders actual album cover image (Image in terminal, Svg in desktop), ▶/⏸ icons, and Login button
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE_SITE, surface })
    expect(await ui.find({ type: 'Text', text: 'Veridis Quo' })).toBeDefined()
    expect(await ui.find({ type: 'Button', key: 'btn-play-toggle' })).toBeDefined()
    expect(await ui.find({ type: 'Button', key: 'btn-spotify-login' })).toBeDefined()
    if (surface === 'terminal') {
      expect(await ui.find({ type: 'Image', key: 'spotify-album-cover' })).toBeDefined()
    } else {
      expect(await ui.find({ type: 'Svg' })).toBeDefined()
    }
    await ui.unmount()
  }
})

test('/spotify voice and Sidebar voice search capture spoken query and play matching track', async ($, on) => {
  const processCalls: string[][] = []
  const toasts: string[] = []
  registerCommonStubs(on, processCalls, toasts)

  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const res = await $.command.run({ command: 'spotify', args: 'voice play daft punk veridis quo' })
  expect(res.text).toContain('Voice Search ("play daft punk veridis quo")')
  expect(res.text).toContain('Veridis Quo')

  const ui = await $.ui.mount({ ...PANE_SITE, surface: 'terminal' })
  await ui.press({ key: 'btn-voice-search' })
  expect(processCalls.some((argv) => argv.includes('voice') && argv.includes('--listen'))).toBe(true)
  expect(await ui.find({ type: 'Text', text: /Voice: "daft punk veridis quo"/ })).toBeDefined()
  await ui.unmount()
})

test('Sidebar buttons switch cleanly between Sidebar, Mini Bar, Popup Window, and Spotify Login', async ($, on) => {
  const processCalls: string[][] = []
  const toasts: string[] = []
  const openedPanes: string[] = []
  const closedPanes: string[] = []
  registerCommonStubs(on, processCalls, toasts, openedPanes, closedPanes)

  await $.command.run({ command: 'spotify', args: '4cOdK2wGLETKBW3PvgPWqT panel' })
  const ui = await $.ui.mount({ ...PANE_SITE, surface: 'terminal' })

  await ui.press({ key: 'btn-spotify-login' })
  expect(processCalls.some((argv) => argv.includes('login'))).toBe(true)

  await ui.press({ key: 'cfg-popup-window' })
  expect(closedPanes).toContain('spotify-mod')
  expect(processCalls.some((argv) => argv.includes('mode') && argv.includes('popup'))).toBe(true)

  await ui.press({ key: 'cfg-mini-controller' })
  expect(processCalls.some((argv) => argv.includes('mode') && argv.includes('mini'))).toBe(true)

  const loginCmd = await $.command.run({ command: 'spotify', args: 'login' })
  expect(loginCmd.text).toContain('Opened Spotify Login window')

  await ui.unmount()
})

test('mcp__spotify-mod__spotify_player tool supports play, login, voice, mini, panel, popup, and stop actions', async ($, on) => {
  registerCommonStubs(on)

  const playRes = await $.tool.call({
    tool: 'mcp__spotify-mod__spotify_player',
    action: 'play',
    queryOrUrl: '4cOdK2wGLETKBW3PvgPWqT',
    mode: 'mini',
    position: 'top-right',
  })
  expect(playRes.result).toContain('mini mode at top-right')

  const loginRes = await $.tool.call({
    tool: 'mcp__spotify-mod__spotify_player',
    action: 'login',
  })
  expect(loginRes.result).toContain('Opened Spotify Login window')

  const panelRes = await $.tool.call({
    tool: 'mcp__spotify-mod__spotify_player',
    action: 'panel',
    position: 'right-side',
  })
  expect(panelRes.result).toContain('side-panel at right-side [sidebar]')

  const popupRes = await $.tool.call({
    tool: 'mcp__spotify-mod__spotify_player',
    action: 'popup',
    position: 'top-right',
  })
  expect(popupRes.result).toContain('popup at top-right [compact]')

  const voiceRes = await $.tool.call({
    tool: 'mcp__spotify-mod__spotify_player',
    action: 'voice',
    queryOrUrl: 'lofi coding beats',
  })
  expect(voiceRes.result).toContain('Voice search ("lofi coding beats")')

  const stopRes = await $.tool.call({
    tool: 'mcp__spotify-mod__spotify_player',
    action: 'stop',
  })
  expect(stopRes.result).toContain('Stopped and closed Spotify Mod')
})
