/**
 * Spotify Mod — Claude Code Plugin
 *
 * Minimal Spotify player with three mutually exclusive modes:
 *   1. "mini" (default)      — Inline status bar above the prompt (no sidebar, no popup window).
 *   2. "side-panel"          — Claude Code sidebar rendering the real album cover PNG image and minimal controls (no popup window).
 *   3. "popup"               — Native macOS floating popup window only (closes the sidebar).
 *
 * Supports Spotify Login (/spotify login) in a persistent WebKit cookie store to unlock full-length tracks.
 */

const PANE_ID = 'spotify-mod';
const STATE_FILE_PATH = '/tmp/claude-spotify-mod-state.json';
const COVER_PNG_FILE_PATH = '/tmp/claude-spotify-mod-cover.png';

const CURATED_TRACKS = [
  {
    id: '0VjIjW4GlUZAMYd2vXMi3b',
    kind: 'track',
    title: 'Blinding Lights',
    artist: 'The Weeknd',
    category: 'Synthwave'
  },
  {
    id: '4cOdK2wGLETKBW3PvgPWqT',
    kind: 'track',
    title: 'Veridis Quo',
    artist: 'Daft Punk',
    category: 'Electronic'
  },
  {
    id: '5ChkMS8OtdzJeqyybCc9R5',
    kind: 'track',
    title: 'Midnight City',
    artist: 'M83',
    category: 'Synthpop'
  },
  {
    id: '37i9dQZF1DWWQRwui0ExPn',
    kind: 'playlist',
    title: 'lofi beats',
    artist: 'Spotify',
    category: 'Focus'
  },
  {
    id: '37i9dQZF1DX5trt9i14X7j',
    kind: 'playlist',
    title: 'Coding Mode',
    artist: 'Spotify',
    category: 'Deep Work'
  }
];

let pluginRootPath = '';
let currentTrack = { ...CURATED_TRACKS[0] };
let isPlaying = false;
let hasActiveTrack = false;
let isUiHidden = false;
let isVoiceListening = false;
let isLoggedIn = false;
let coverGeneration = 1;
let lastVoiceTranscript = '';

// Mutually exclusive controllerMode: 'mini' | 'side-panel' | 'popup'
let controllerMode = 'mini';
let screenPosition = 'top-right';
let customCoords = '';
let sizePreset = 'mini';
let opacity = 0.96;
let uiPlacement = 'both';
let paneColumns = 38;
let playlist = [...CURATED_TRACKS];

export function extractSpotifyTarget(raw) {
  if (!raw || typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;

  const uriMatch = trimmed.match(/^spotify:(track|playlist|album|artist|episode):([A-Za-z0-9]{22})$/i);
  if (uriMatch) {
    return {
      kind: uriMatch[1].toLowerCase(),
      id: uriMatch[2]
    };
  }

  const urlMatch = trimmed.match(
    /open\.spotify\.com\/(?:intl-[a-z]{2}\/)?(?:embed\/)?(track|playlist|album|artist|episode)\/([A-Za-z0-9]{22})/i
  );
  if (urlMatch) {
    return {
      kind: urlMatch[1].toLowerCase(),
      id: urlMatch[2]
    };
  }

  if (/^[A-Za-z0-9]{22}$/.test(trimmed) && /[0-9]/.test(trimmed) && /[A-Za-z]/.test(trimmed)) {
    return {
      kind: 'track',
      id: trimmed
    };
  }

  return null;
}

export function normalizeControllerMode(raw) {
  if (!raw || typeof raw !== 'string') return 'mini';
  const v = raw.trim().toLowerCase();
  if (
    v === 'side-panel' ||
    v === 'panel' ||
    v === 'side' ||
    v === 'sidebar' ||
    v === 'pull' ||
    v === 'pull-panel' ||
    v === 'drawer' ||
    v === 'full'
  ) {
    return 'side-panel';
  }
  if (
    v === 'popup' ||
    v === 'pop-up' ||
    v === 'window' ||
    v === 'compact' ||
    v === 'card' ||
    v === 'compact-card' ||
    v === 'float'
  ) {
    return 'popup';
  }
  return 'mini';
}

export function normalizePosition(raw) {
  if (!raw || typeof raw !== 'string') return 'top-right';
  const v = raw.trim().toLowerCase();
  const map = {
    tl: 'top-left',
    'top-left': 'top-left',
    topleft: 'top-left',
    nw: 'top-left',
    tc: 'top-center',
    'top-center': 'top-center',
    top: 'top-center',
    north: 'top-center',
    tr: 'top-right',
    'top-right': 'top-right',
    topright: 'top-right',
    ne: 'top-right',
    l: 'left-side',
    left: 'left-side',
    'left-side': 'left-side',
    west: 'left-side',
    'dock-left': 'left-side',
    'pull-left': 'left-side',
    c: 'center',
    center: 'center',
    middle: 'center',
    r: 'right-side',
    right: 'right-side',
    'right-side': 'right-side',
    east: 'right-side',
    'dock-right': 'right-side',
    'pull-right': 'right-side',
    bl: 'bottom-left',
    'bottom-left': 'bottom-left',
    bottomleft: 'bottom-left',
    sw: 'bottom-left',
    bc: 'bottom-center',
    'bottom-center': 'bottom-center',
    bottom: 'bottom-center',
    south: 'bottom-center',
    br: 'bottom-right',
    'bottom-right': 'bottom-right',
    bottomright: 'bottom-right',
    se: 'bottom-right',
    custom: 'custom'
  };
  if (map[v]) return map[v];
  if (/^\d+\s*,\s*\d+/.test(v)) return 'custom';
  return 'top-right';
}

function hashTrackSeed(track) {
  const s = ((track && track.title) || 'Spotify') + ':' + ((track && track.artist) || '');
  let h = 2166136261;
  for (let i = 0; i < s.length; i += 1) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

function buildAlbumCoverSvg(track) {
  const seed = hashTrackSeed(track);
  const colors = ['#1DB954', '#3B82F6', '#EC4899', '#F59E0B', '#14B8A6'];
  const accent = colors[seed % colors.length];
  return (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120">' +
    '<rect x="2" y="2" width="116" height="116" rx="10" fill="#0B0F14" stroke="' +
    accent +
    '" stroke-width="2"/>' +
    '<circle cx="60" cy="60" r="42" fill="#141A22" stroke="' +
    accent +
    '" stroke-width="2"/>' +
    '<circle cx="60" cy="60" r="28" fill="none" stroke="#263238" stroke-width="1.5"/>' +
    '<circle cx="60" cy="60" r="12" fill="' +
    accent +
    '"/>' +
    '<circle cx="60" cy="60" r="4" fill="#0B0F14"/>' +
    '</svg>'
  );
}

async function persistSettings($) {
  await $.store.set('currentTrack', currentTrack);
  await $.store.set('controllerMode', controllerMode);
  await $.store.set('screenPosition', screenPosition);
  await $.store.set('customCoords', customCoords);
  await $.store.set('sizePreset', sizePreset);
  await $.store.set('opacity', opacity);
  await $.store.set('uiPlacement', uiPlacement);
  await $.store.set('paneColumns', paneColumns);
  await $.store.set('playlist', playlist);
  await $.store.set('isLoggedIn', isLoggedIn);
}

async function loadSavedSettings($) {
  const savedTrack = await $.store.get('currentTrack');
  if (savedTrack && typeof savedTrack === 'object' && savedTrack.id) {
    currentTrack = savedTrack;
  }
  const savedMode = await $.store.get('controllerMode');
  if (typeof savedMode === 'string' && savedMode) {
    controllerMode = normalizeControllerMode(savedMode);
  }
  const savedPos = await $.store.get('screenPosition');
  if (typeof savedPos === 'string' && savedPos) {
    screenPosition = savedPos;
  }
  const savedCustom = await $.store.get('customCoords');
  if (typeof savedCustom === 'string') {
    customCoords = savedCustom;
  }
  const savedSize = await $.store.get('sizePreset');
  if (typeof savedSize === 'string' && savedSize) {
    sizePreset = savedSize;
  }
  const savedOpacity = await $.store.get('opacity');
  if (typeof savedOpacity === 'number') {
    opacity = savedOpacity;
  }
  const savedPlacement = await $.store.get('uiPlacement');
  if (typeof savedPlacement === 'string' && savedPlacement) {
    uiPlacement = savedPlacement;
  }
  const savedCols = await $.store.get('paneColumns');
  if (typeof savedCols === 'number') {
    paneColumns = savedCols;
  }
  const savedPlaylist = await $.store.get('playlist');
  if (Array.isArray(savedPlaylist) && savedPlaylist.length > 0) {
    playlist = savedPlaylist;
  }
  const savedLoggedIn = await $.store.get('isLoggedIn');
  if (typeof savedLoggedIn === 'boolean') {
    isLoggedIn = savedLoggedIn;
  }
}

export function cleanMusicQuery(raw) {
  let q = String(raw || '').trim();
  const prefixes = [
    'how about ',
    'what about ',
    'can you play ',
    'could you play ',
    'please play ',
    'play some ',
    'play ',
    'put on ',
    'listen to ',
    'search for ',
    'search ',
    'find ',
    'i want to hear ',
    "let's hear "
  ];
  const lower = q.toLowerCase();
  for (const prefix of prefixes) {
    if (lower.startsWith(prefix)) {
      q = q.slice(prefix.length);
      break;
    }
  }
  q = q.replace(/^[?!.,;:\s]+|[?!.,;:\s]+$/g, '');
  return q || String(raw || '').trim();
}

async function resolveSpotifyMetadata($, target, fallbackTitle, fallbackArtist, fallbackAudioUrl, fallbackArtworkUrl) {
  const kind = (target && target.kind) || 'track';
  const id = (target && target.id) || CURATED_TRACKS[0].id;

  if (fallbackAudioUrl && fallbackTitle) {
    return {
      id,
      kind,
      title: fallbackTitle,
      artist: fallbackArtist || 'Spotify',
      audioUrl: fallbackAudioUrl,
      artworkUrl: fallbackArtworkUrl || ''
    };
  }

  const isSpotifyId = /^[A-Za-z0-9]{22}$/.test(id);
  if (isSpotifyId) {
    const webUrl = 'https://open.spotify.com/' + kind + '/' + id;
    const oembedUrl = 'https://open.spotify.com/oembed?url=' + encodeURIComponent(webUrl);

    try {
      const res = await $.http.fetch(oembedUrl);
      if (res && res.ok && res.text) {
        const data = JSON.parse(res.text);
        if (data && (data.title || data.author_name)) {
          return {
            id,
            kind,
            title: data.title || fallbackTitle || 'Spotify ' + kind + ' (' + id + ')',
            artist: data.author_name || fallbackArtist || 'Spotify',
            audioUrl: fallbackAudioUrl || '',
            artworkUrl: data.thumbnail_url || fallbackArtworkUrl || ''
          };
        }
      }
    } catch {
      // Offline or test environment fallback
    }
  }

  const curated = CURATED_TRACKS.find((t) => t.id === id);
  if (curated) {
    return { ...curated, audioUrl: fallbackAudioUrl || '', artworkUrl: fallbackArtworkUrl || '' };
  }
  return {
    id,
    kind,
    title: fallbackTitle || 'Spotify ' + kind + ' (' + id + ')',
    artist: fallbackArtist || 'Spotify',
    audioUrl: fallbackAudioUrl || '',
    artworkUrl: fallbackArtworkUrl || ''
  };
}

export async function searchSpotifyTracks($, query) {
  const cleaned = cleanMusicQuery(query);
  if (!cleaned) return [];
  const lower = cleaned.toLowerCase();

  const localMatches = playlist.filter(
    (t) =>
      t.title.toLowerCase().includes(lower) ||
      (t.artist && t.artist.toLowerCase().includes(lower)) ||
      (t.category && t.category.toLowerCase().includes(lower))
  );
  const exactCurated = CURATED_TRACKS.find((t) => t.title.toLowerCase() === lower);
  const searchTerm =
    exactCurated && exactCurated.artist && !exactCurated.artist.toLowerCase().includes('spotify')
      ? exactCurated.title + ' ' + exactCurated.artist
      : cleaned;

  try {
    const searchUrl =
      'https://itunes.apple.com/search?media=music&entity=song&limit=8&term=' +
      encodeURIComponent(searchTerm);
    const res = await $.http.fetch(searchUrl);
    if (res && res.ok && res.text) {
      const parsed = JSON.parse(res.text);
      if (parsed && Array.isArray(parsed.results) && parsed.results.length > 0) {
        const tracks = parsed.results
          .filter((item) => item && (item.trackName || item.collectionName))
          .map((item) => ({
            id: item.trackId ? String(item.trackId) : CURATED_TRACKS[0].id,
            kind: 'track',
            title: item.trackName || item.collectionName || cleaned,
            artist: item.artistName || 'Spotify',
            category: item.primaryGenreName || 'Search',
            audioUrl: item.previewUrl || '',
            artworkUrl: item.artworkUrl100 || ''
          }));
        if (tracks.length > 0) {
          return tracks;
        }
      }

      const results = [];
      const seen = new Set();
      const trackRegex = /spotify:(track|playlist):([A-Za-z0-9]{22})/g;
      let match = trackRegex.exec(res.text);
      while (match && results.length < 6) {
        const kind = match[1].toLowerCase();
        const id = match[2];
        if (!seen.has(id)) {
          seen.add(id);
          results.push({
            id,
            kind,
            title: cleaned,
            artist: 'Spotify Search'
          });
        }
        match = trackRegex.exec(res.text);
      }
      if (results.length > 0) {
        return results;
      }
    }
  } catch {
    // Ignore and fall back to local curated catalog
  }

  if (localMatches.length > 0) {
    return localMatches;
  }

  return [
    {
      id: CURATED_TRACKS[0].id,
      kind: 'track',
      title: cleaned,
      artist: 'Spotify Search',
      query: cleaned
    },
    ...CURATED_TRACKS.slice(0, 3)
  ];
}

async function runNativePlayerCommand($, args) {
  const binPath = pluginRootPath + '/bin/spotify-pip';
  try {
    const res = await $.process.run([binPath, ...args]);
    if (res && res.stdout) {
      try {
        const parsed = JSON.parse(String(res.stdout).trim());
        if (parsed && typeof parsed === 'object') {
          if (parsed.artworkUrl && !currentTrack.artworkUrl) {
            currentTrack = { ...currentTrack, artworkUrl: parsed.artworkUrl };
          }
          if (typeof parsed.artworkGeneration === 'number') {
            coverGeneration = parsed.artworkGeneration;
          }
          if (typeof parsed.isLoggedIn === 'boolean') {
            isLoggedIn = parsed.isLoggedIn;
          }
        }
      } catch {
        // Ignore non-JSON output
      }
    }
    return res;
  } catch {
    return { exitCode: 1, stdout: '', stderr: '' };
  }
}

async function syncFromNativeStateFile($) {
  try {
    const raw = await $.fs.read(STATE_FILE_PATH);
    if (!raw) return;
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object') {
      if (parsed.position) {
        screenPosition = parsed.position;
      }
      if (parsed.controllerMode) {
        controllerMode = normalizeControllerMode(parsed.controllerMode);
      }
      if (typeof parsed.customX === 'number' && typeof parsed.customY === 'number') {
        customCoords = Math.round(parsed.customX) + ',' + Math.round(parsed.customY);
      }
      if (typeof parsed.isPaused === 'boolean') {
        isPlaying = !parsed.shouldQuit && !parsed.isPaused;
      }
      if (typeof parsed.isLoggedIn === 'boolean') {
        isLoggedIn = parsed.isLoggedIn;
      }
      if (typeof parsed.artworkGeneration === 'number') {
        coverGeneration = parsed.artworkGeneration;
      }
      if (typeof parsed.title === 'string' && parsed.title.trim()) {
        currentTrack = {
          ...currentTrack,
          id: parsed.trackId || currentTrack.id,
          kind: parsed.kind || currentTrack.kind || 'track',
          title: parsed.title.trim(),
          artist: parsed.artist || currentTrack.artist || 'Spotify',
          audioUrl: parsed.audioUrl || currentTrack.audioUrl || '',
          artworkUrl: parsed.artworkUrl || currentTrack.artworkUrl || ''
        };
      }
      if (typeof parsed.lastVoiceQuery === 'string' && parsed.lastVoiceQuery.trim()) {
        lastVoiceTranscript = parsed.lastVoiceQuery.trim();
      }
    }
  } catch {
    // Ignore missing state file before first launch
  }
}

async function openPlayerPane($, { focus = true } = {}) {
  await $.ui.open({
    id: PANE_ID,
    title: 'Spotify',
    ...(focus ? { focus: true } : {}),
    closeOnEscape: true,
    columns: paneColumns
  });
}

// Mutually exclusive controller mode switching:
//   - 'mini': inline status bar only (closes Sidebar pane, hides macOS popup window)
//   - 'side-panel': Sidebar pane only (opens Sidebar pane, hides macOS popup window)
//   - 'popup': macOS popup window only (closes Sidebar pane, shows macOS popup window)
async function setControllerConfiguration($, modeInput, requestedPos) {
  const nextMode = normalizeControllerMode(modeInput);
  controllerMode = nextMode;
  hasActiveTrack = true;
  isUiHidden = false;

  if (nextMode === 'mini') {
    sizePreset = 'mini';
    if (requestedPos) {
      screenPosition = normalizePosition(requestedPos);
    }
    await $.ui.close({ id: PANE_ID });
  } else if (nextMode === 'side-panel') {
    sizePreset = 'sidebar';
    screenPosition = requestedPos ? normalizePosition(requestedPos) : 'right-side';
    if (screenPosition !== 'right-side' && screenPosition !== 'left-side') {
      screenPosition = 'right-side';
    }
    if (!currentTrack.artworkUrl) {
      const meta = await resolveSpotifyMetadata(
        $,
        { kind: currentTrack.kind || 'track', id: currentTrack.id },
        currentTrack.title,
        currentTrack.artist,
        currentTrack.audioUrl,
        currentTrack.artworkUrl
      );
      currentTrack = { ...currentTrack, ...meta };
    }
    await openPlayerPane($, { focus: false });
  } else {
    // 'popup' mode: close the Claude Code sidebar so ONLY the popup window is shown
    sizePreset = 'compact';
    if (requestedPos) {
      screenPosition = normalizePosition(requestedPos);
    }
    await $.ui.close({ id: PANE_ID });
  }

  const posArg = screenPosition === 'custom' && customCoords ? customCoords : screenPosition;
  const modeArgs = [
    'mode',
    controllerMode,
    '--position',
    posArg,
    '--size',
    sizePreset,
    '--title',
    currentTrack.title || 'Spotify',
    '--artist',
    currentTrack.artist || 'Spotify'
  ];
  if (currentTrack.artworkUrl) {
    modeArgs.push('--artwork-url', currentTrack.artworkUrl);
  }
  await runNativePlayerCommand($, modeArgs);
  await syncFromNativeStateFile($);
  await persistSettings($);
  $.ui.invalidate('ui.render');
  return { controllerMode, screenPosition, sizePreset };
}

async function openSpotifyLogin($) {
  hasActiveTrack = true;
  isUiHidden = false;
  await runNativePlayerCommand($, ['login']);
  await syncFromNativeStateFile($);
  await persistSettings($);
  $.ui.toast('Opened Spotify Login window. Sign in to unlock full-length tracks.');
  $.ui.invalidate('ui.render');
}

async function logoutSpotify($) {
  isLoggedIn = false;
  await runNativePlayerCommand($, ['logout']);
  await syncFromNativeStateFile($);
  await persistSettings($);
  $.ui.toast('Logged out of Spotify.');
  $.ui.invalidate('ui.render');
}

async function playSpotifyTarget($, rawTarget, requestedPos, requestedModeOrSize) {
  if (requestedPos) {
    const norm = normalizePosition(requestedPos);
    screenPosition = norm;
    if (norm === 'custom') {
      customCoords = String(requestedPos).trim();
    }
  }
  if (requestedModeOrSize) {
    const m = String(requestedModeOrSize).trim().toLowerCase();
    if (
      m === 'mini' ||
      m === 'tiny' ||
      m === 'panel' ||
      m === 'side-panel' ||
      m === 'sidebar' ||
      m === 'pull' ||
      m === 'popup' ||
      m === 'pop-up' ||
      m === 'window' ||
      m === 'card' ||
      m === 'compact'
    ) {
      controllerMode = normalizeControllerMode(m);
      sizePreset =
        controllerMode === 'side-panel'
          ? 'sidebar'
          : controllerMode === 'mini'
            ? 'mini'
            : 'compact';
    } else {
      sizePreset = m;
    }
  }

  const trimmed = String(rawTarget || '').trim();
  let parsedTarget = extractSpotifyTarget(trimmed);
  let resolvedMeta = null;

  const existingItem = playlist.find((item) => item.id === trimmed);
  if (existingItem && !parsedTarget) {
    parsedTarget = { kind: existingItem.kind || 'track', id: existingItem.id };
    resolvedMeta = existingItem;
  }

  if (!parsedTarget && trimmed) {
    const found = await searchSpotifyTracks($, trimmed);
    if (found.length > 0) {
      parsedTarget = {
        kind: found[0].kind || 'track',
        id: found[0].id
      };
      resolvedMeta = found[0];
      const merged = [...found];
      for (const oldItem of playlist) {
        if (!merged.some((m) => m.id === oldItem.id) && merged.length < 18) {
          merged.push(oldItem);
        }
      }
      playlist = merged;
    }
  }

  if (!parsedTarget) {
    parsedTarget = {
      kind: currentTrack.kind || 'track',
      id: currentTrack.id || CURATED_TRACKS[0].id
    };
    resolvedMeta = currentTrack;
  }

  const meta = await resolveSpotifyMetadata(
    $,
    parsedTarget,
    resolvedMeta ? resolvedMeta.title : '',
    resolvedMeta ? resolvedMeta.artist : '',
    resolvedMeta ? resolvedMeta.audioUrl : '',
    resolvedMeta ? resolvedMeta.artworkUrl : ''
  );
  currentTrack = meta;
  isPlaying = true;
  hasActiveTrack = true;
  coverGeneration += 1;

  if (!playlist.some((item) => item.id === meta.id)) {
    playlist = [meta, ...playlist.slice(0, 14)];
  }

  const posArg = screenPosition === 'custom' && customCoords ? customCoords : screenPosition;
  const cmdArgs = [
    'play',
    meta.id,
    '--kind',
    meta.kind || 'track',
    '--mode',
    controllerMode,
    '--position',
    posArg,
    '--size',
    sizePreset,
    '--title',
    meta.title,
    '--artist',
    meta.artist || 'Spotify',
    '--opacity',
    String(opacity)
  ];
  if (meta.audioUrl) {
    cmdArgs.push('--audio-url', meta.audioUrl);
  }
  if (meta.artworkUrl) {
    cmdArgs.push('--artwork-url', meta.artworkUrl);
  }
  await runNativePlayerCommand($, cmdArgs);

  // Sync back any resolved artworkGeneration or login state written by native binary
  await syncFromNativeStateFile($);

  await persistSettings($);
  $.ui.invalidate('ui.render');
  return currentTrack;
}

async function runVoiceSearch($, spokenTextOverride) {
  isVoiceListening = true;
  hasActiveTrack = true;
  $.ui.invalidate('ui.render');

  let transcript = String(spokenTextOverride || '').trim();

  if (!transcript) {
    $.ui.toast('Listening for voice search... Speak a song or artist.');
    const res = await runNativePlayerCommand($, ['voice', '--listen', '4']);
    const out = String((res && res.stdout) || '').trim();
    if (out) {
      try {
        const parsed = JSON.parse(out);
        transcript = String(parsed.lastVoiceQuery || parsed.transcript || '').trim();
      } catch {
        transcript = out.split('\n').pop() || '';
      }
    }
  }

  isVoiceListening = false;

  if (!transcript) {
    $.ui.toast('No voice query captured. Click Voice or run /spotify voice <query>.');
    $.ui.invalidate('ui.render');
    return null;
  }

  lastVoiceTranscript = transcript;
  const meta = await playSpotifyTarget($, transcript, null, null);
  $.ui.toast('Voice matched "' + meta.title + '" - ' + (meta.artist || 'Spotify'));
  return { transcript, track: meta };
}

async function movePlayerPosition($, newPos, newSizeOrMode) {
  const raw = String(newPos || '').trim();
  if (raw === 'pane' || raw === 'band' || raw === 'both' || raw === 'spinner') {
    uiPlacement = raw;
    await persistSettings($);
    $.ui.invalidate('ui.render');
    return { kind: 'ui', placement: uiPlacement };
  }

  const norm = normalizePosition(raw);
  screenPosition = norm;
  if (norm === 'custom') {
    customCoords = raw;
  }
  if (newSizeOrMode) {
    const token = String(newSizeOrMode).trim().toLowerCase();
    if (token === 'mini' || token === 'side-panel' || token === 'panel' || token === 'sidebar' || token === 'popup') {
      controllerMode = normalizeControllerMode(token);
      sizePreset = controllerMode === 'side-panel' ? 'sidebar' : controllerMode === 'mini' ? 'mini' : 'compact';
    } else {
      sizePreset = token;
    }
  }

  const posArg = screenPosition === 'custom' && customCoords ? customCoords : screenPosition;
  await runNativePlayerCommand($, ['position', posArg, sizePreset, '--mode', controllerMode]);
  await persistSettings($);
  $.ui.invalidate('ui.render');
  return { kind: 'screen', position: screenPosition, sizePreset, controllerMode };
}

const SPOTIFY_HELP = [
  '/spotify                        show inline mini status bar (default: no sidebar, no popup)',
  '/spotify <url|uri|search>       search and play track, album, or playlist',
  '/spotify voice [spoken query]   voice-enabled search via microphone or spoken phrase',
  '/spotify login | logout         sign in to Spotify account for full-length tracks',
  '/spotify mini                   use inline mini status bar only',
  '/spotify panel                  open sidebar player only (no popup window)',
  '/spotify popup                  open floating popup window only (closes sidebar)',
  '/spotify pause | resume | next | prev | stop | status'
].join('\n');

async function stopPlayback($) {
  isPlaying = false;
  hasActiveTrack = false;
  await runNativePlayerCommand($, ['stop']);
  await $.ui.close({ id: PANE_ID });
  $.ui.invalidate('ui.render');
}

async function stepPlaylist($, delta) {
  if (playlist.length === 0) return currentTrack;
  const idx = playlist.findIndex((item) => item.id === currentTrack.id);
  const nextIdx = idx === -1 ? 0 : (idx + delta + playlist.length) % playlist.length;
  const nextItem = playlist[nextIdx];
  return playSpotifyTarget($, nextItem.id, null, null);
}

function describeConfig() {
  const modeLabel =
    controllerMode === 'mini'
      ? 'Inline Mini Bar'
      : controllerMode === 'side-panel'
        ? 'Sidebar'
        : 'Popup Window';
  return (
    'Mode: ' +
    modeLabel +
    ' (' +
    controllerMode +
    ') | Position: ' +
    screenPosition +
    ' [' +
    sizePreset +
    '] | Account: ' +
    (isLoggedIn ? 'Logged In' : 'Guest') +
    (lastVoiceTranscript ? ' | Last Voice: "' + lastVoiceTranscript + '"' : '')
  );
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    await loadSavedSettings($);
    pluginRootPath = $.plugin.root;

    try {
      await $.command.register({
        name: 'spotify',
        description:
          'Spotify Mod: inline mini bar, sidebar with album cover image, popup player, and Spotify Login',
        argumentHint:
          '[play <url|search> | voice [query] | login | logout | mini | panel | popup | pause | resume | next | prev | stop | status]',
        immediate: true
      });
    } catch {
      // Ignore duplicate command registration on reload
    }

    try {
      await $.tool.register({
        name: 'spotify_player',
        description:
          'Play songs or playlists on Spotify, run voice-enabled music search, login to Spotify, or switch between inline mini bar, sidebar, and popup window.',
        inputSchema: {
          type: 'object',
          properties: {
            action: {
              type: 'string',
              description:
                'play, search, voice, login, logout, mini, panel, popup, mode, position, pause, resume, next, prev, stop, or status'
            },
            queryOrUrl: {
              type: 'string',
              description: 'Spotify URL, URI, 22-character ID, search query, or spoken voice transcript'
            },
            mode: {
              type: 'string',
              description: 'mini (inline bar only), side-panel (sidebar only), or popup (popup window only)'
            },
            position: {
              type: 'string',
              description:
                'top-right, top-left, bottom-right, bottom-left, right-side, left-side, top-center, bottom-center, center, or custom x,y,w,h'
            },
            size: {
              type: 'string',
              description: 'mini, compact, large, or sidebar'
            }
          },
          required: ['action']
        }
      });
    } catch {
      // Ignore duplicate tool registration on reload
    }

    return next(e);
  });

  on('classic.SessionStart', { source: 'clear' }, async ($, e, next) => {
    try {
      await loadSavedSettings($);
    } catch {
      // Non-fatal
    }
    return next(e);
  });

  on('command.run', { command: 'spotify' }, async ($, e) => {
    const rawArgs = String(e.args || '').trim();
    await syncFromNativeStateFile($);

    const [first = '', ...rest] = rawArgs.split(/\s+/).filter(Boolean);
    const sub = first.toLowerCase();
    const restText = rest.join(' ');

    if (!sub || sub === 'show') {
      isUiHidden = false;
      hasActiveTrack = true;
      if (controllerMode === 'side-panel') {
        await openPlayerPane($, { focus: !sub });
      } else {
        await $.ui.close({ id: PANE_ID });
      }
      $.ui.invalidate('ui.render');
      return {};
    }
    if (sub === 'help') {
      return { text: SPOTIFY_HELP };
    }
    if (sub === 'login' || sub === 'auth' || sub === 'signin') {
      await openSpotifyLogin($);
      return {
        text: 'Opened Spotify Login window. Sign in to your Spotify account to play full-length songs instead of 30s previews.'
      };
    }
    if (sub === 'logout' || sub === 'signout') {
      await logoutSpotify($);
      return {
        text: 'Logged out of Spotify account.'
      };
    }
    if (sub === 'mini' || sub === 'tiny') {
      await setControllerConfiguration($, 'mini', rest[0] || null);
      return {
        text: 'Switched Spotify Mod to inline Mini Bar.'
      };
    }
    if (sub === 'panel' || sub === 'side-panel' || sub === 'sidebar' || sub === 'pull') {
      const side = rest[0] ? normalizePosition(rest[0]) : 'right-side';
      const cfg = await setControllerConfiguration($, 'side-panel', side);
      return {
        text: 'Opened Spotify Sidebar (' + cfg.screenPosition + ' [' + cfg.sizePreset + ']).'
      };
    }
    if (sub === 'popup' || sub === 'pop-up' || sub === 'window' || sub === 'card') {
      const cfg = await setControllerConfiguration($, 'popup', rest[0] || 'top-right');
      return {
        text: 'Opened Spotify Popup Window (' + cfg.screenPosition + ').'
      };
    }
    if (sub === 'mode') {
      if (!rest[0]) {
        return { text: describeConfig() };
      }
      const cfg = await setControllerConfiguration($, rest[0], rest[1] || null);
      return {
        text:
          'Configured Spotify Mod mode: ' +
          cfg.controllerMode +
          ' at ' +
          cfg.screenPosition +
          ' [' +
          cfg.sizePreset +
          '].'
      };
    }
    if (sub === 'voice' || sub === 'listen' || sub === 'mic') {
      isUiHidden = false;
      hasActiveTrack = true;
      if (controllerMode === 'side-panel') {
        await openPlayerPane($, { focus: false });
      }
      const voiceRes = await runVoiceSearch($, restText);
      if (!voiceRes) {
        return { text: 'Voice search ready. Click Voice in the status bar or pass /spotify voice <query>.' };
      }
      return {
        text:
          'Voice Search ("' +
          voiceRes.transcript +
          '") -> Playing "' +
          voiceRes.track.title +
          '" by ' +
          (voiceRes.track.artist || 'Spotify')
      };
    }
    if (sub === 'pause' || sub === 'resume') {
      const wantPlaying = sub === 'resume' || !isPlaying;
      if (wantPlaying) {
        const meta = await playSpotifyTarget($, currentTrack.id, screenPosition, controllerMode);
        return { text: 'Resumed: ' + meta.title + ' - ' + meta.artist };
      }
      isPlaying = false;
      await runNativePlayerCommand($, ['pause']);
      $.ui.invalidate('ui.render');
      return { text: 'Paused: ' + currentTrack.title + ' - ' + currentTrack.artist };
    }
    if (sub === 'next' || sub === 'skip') {
      const nextMeta = await stepPlaylist($, 1);
      return { text: 'Next track: ' + nextMeta.title + ' - ' + nextMeta.artist };
    }
    if (sub === 'prev' || sub === 'previous' || sub === 'back') {
      const prevMeta = await stepPlaylist($, -1);
      return { text: 'Previous track: ' + prevMeta.title + ' - ' + prevMeta.artist };
    }
    if (sub === 'stop') {
      await stopPlayback($);
      return { text: 'Stopped Spotify Mod.' };
    }
    if (sub === 'hide') {
      isUiHidden = true;
      await $.ui.close({ id: PANE_ID });
      $.ui.invalidate('ui.render');
      return {
        text: 'Spotify Mod UI hidden' + (isPlaying ? ' (still playing; /spotify show to bring it back).' : '.')
      };
    }
    if (sub === 'pos' || sub === 'position') {
      if (!restText) {
        return { text: describeConfig() };
      }
      const [posToken, sizeToken] = rest;
      const updated = await movePlayerPosition($, posToken, sizeToken);
      if (updated.kind === 'ui') {
        return { text: 'Spotify Mod UI placement set to: ' + updated.placement };
      }
      return {
        text:
          'Moved Spotify Mod to ' +
          updated.position +
          (screenPosition === 'custom' && customCoords ? ' (' + customCoords + ')' : '') +
          ' [' +
          updated.sizePreset +
          '] (' +
          updated.controllerMode +
          ')'
      };
    }
    if (sub === 'width') {
      const cols = Number(rest[0]);
      if (!Number.isInteger(cols) || cols < 28 || cols > 160) {
        return { text: 'Usage: /spotify width <28-160> (now ' + paneColumns + ')' };
      }
      paneColumns = cols;
      await persistSettings($);
      if (!isUiHidden && controllerMode === 'side-panel') {
        await $.ui.close({ id: PANE_ID });
        await openPlayerPane($, { focus: false });
      }
      $.ui.invalidate('ui.render');
      return { text: 'Sidebar width set to ' + cols + ' columns.' };
    }
    if (sub === 'status') {
      return {
        text:
          (isPlaying ? 'Playing: ' : 'Paused: ') +
          currentTrack.title +
          ' - ' +
          (currentTrack.artist || 'Spotify') +
          '\n' +
          describeConfig()
      };
    }

    const parts = sub === 'play' || sub === 'search' ? rest.slice() : rawArgs.split(/\s+/);
    let modeOrSizeOverride = null;
    let posOverride = null;

    const knownModesAndSizes = new Set([
      'mini',
      'tiny',
      'compact',
      'large',
      'sidebar',
      'panel',
      'side-panel',
      'popup',
      'pop-up',
      'window',
      'card'
    ]);
    const knownPositions = new Set([
      'top-left',
      'top-center',
      'top-right',
      'left-side',
      'center',
      'right-side',
      'bottom-left',
      'bottom-center',
      'bottom-right',
      'tl',
      'tc',
      'tr',
      'bl',
      'bc',
      'br',
      'left',
      'right',
      'top',
      'bottom',
      'dock-left',
      'dock-right',
      'pull-left',
      'pull-right'
    ]);

    if (parts.length >= 2 && knownModesAndSizes.has(parts[parts.length - 1].toLowerCase())) {
      modeOrSizeOverride = parts.pop().toLowerCase();
    }
    if (parts.length >= 2) {
      const last = parts[parts.length - 1];
      if (last.startsWith('@')) {
        posOverride = parts.pop().slice(1);
      } else if (knownPositions.has(last.toLowerCase()) || /^\d+,\d+/.test(last)) {
        posOverride = parts.pop();
      }
    }

    isUiHidden = false;
    const meta = await playSpotifyTarget($, parts.join(' '), posOverride, modeOrSizeOverride);
    if (controllerMode === 'side-panel') {
      await openPlayerPane($, { focus: false });
    } else {
      await $.ui.close({ id: PANE_ID });
    }
    $.ui.toast(
      'Playing "' +
        meta.title +
        '" - ' +
        (meta.artist || 'Spotify')
    );
    return {};
  });

  on('tool.call', { tool: 'mcp__spotify-mod__spotify_player' }, async ($, e) => {
    try {
      const action = String(e.action || 'status').toLowerCase();
      if (action === 'play' || action === 'search') {
        const meta = await playSpotifyTarget($, e.queryOrUrl || '', e.position, e.mode || e.size);
        if (controllerMode === 'side-panel') {
          await openPlayerPane($, { focus: false });
        } else {
          await $.ui.close({ id: PANE_ID });
        }
        return {
          result:
            'Playing "' +
            meta.title +
            '" by ' +
            (meta.artist || 'Spotify') +
            ' (' +
            meta.id +
            ') in ' +
            controllerMode +
            ' mode at ' +
            screenPosition +
            ' [' +
            sizePreset +
            '].'
        };
      }
      if (action === 'login' || action === 'auth') {
        await openSpotifyLogin($);
        return {
          result: 'Opened Spotify Login window so the user can authenticate for full-length tracks.'
        };
      }
      if (action === 'logout') {
        await logoutSpotify($);
        return {
          result: 'Logged out of Spotify account.'
        };
      }
      if (action === 'voice' || action === 'listen') {
        const voiceRes = await runVoiceSearch($, e.queryOrUrl || '');
        if (!voiceRes) {
          return { result: 'Voice search triggered; waiting for microphone input.' };
        }
        return {
          result:
            'Voice search ("' +
            voiceRes.transcript +
            '") playing "' +
            voiceRes.track.title +
            '" by ' +
            (voiceRes.track.artist || 'Spotify') +
            '.'
        };
      }
      if (action === 'mini' || action === 'panel' || action === 'popup' || action === 'mode') {
        const targetMode =
          action === 'mini'
            ? 'mini'
            : action === 'panel'
              ? 'side-panel'
              : action === 'popup'
                ? 'popup'
                : e.mode || 'mini';
        const cfg = await setControllerConfiguration($, targetMode, e.position || null);
        return {
          result:
            'Configured Spotify Mod to ' +
            cfg.controllerMode +
            ' at ' +
            cfg.screenPosition +
            ' [' +
            cfg.sizePreset +
            '].'
        };
      }
      if (action === 'position' || action === 'move') {
        const updated = await movePlayerPosition($, e.position || 'top-right', e.size || e.mode);
        return {
          result:
            updated.kind === 'ui'
              ? 'Updated Claude UI placement to ' + updated.placement
              : 'Moved Spotify Mod to ' +
                updated.position +
                ' [' +
                updated.sizePreset +
                '] (' +
                updated.controllerMode +
                ')'
        };
      }
      if (action === 'pause') {
        isPlaying = false;
        await runNativePlayerCommand($, ['pause']);
        $.ui.invalidate('ui.render');
        return { result: 'Paused Spotify Mod.' };
      }
      if (action === 'resume') {
        const meta = await playSpotifyTarget($, currentTrack.id, screenPosition, controllerMode);
        return { result: 'Resumed Spotify Mod: "' + meta.title + '" by ' + meta.artist };
      }
      if (action === 'next') {
        const nextMeta = await stepPlaylist($, 1);
        return { result: 'Skipped to next track: "' + nextMeta.title + '" by ' + nextMeta.artist };
      }
      if (action === 'prev' || action === 'previous') {
        const prevMeta = await stepPlaylist($, -1);
        return { result: 'Returned to previous track: "' + prevMeta.title + '" by ' + prevMeta.artist };
      }
      if (action === 'stop') {
        await stopPlayback($);
        return { result: 'Stopped and closed Spotify Mod.' };
      }
      return {
        result: JSON.stringify({
          track: currentTrack,
          isPlaying,
          isLoggedIn,
          controllerMode,
          screenPosition,
          sizePreset,
          uiPlacement,
          lastVoiceTranscript
        })
      };
    } catch (err) {
      return {
        result: 'Spotify Mod error: ' + (err && err.message ? err.message : String(err))
      };
    }
  });

  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    if (!isPlaying) {
      return next(e);
    }
    const shortTitle =
      currentTrack.title.length > 26 ? currentTrack.title.slice(0, 23) + '...' : currentTrack.title;
    return next({
      ...e,
      props: {
        ...e.props,
        suffix: ' | Spotify: ' + shortTitle
      }
    });
  });

  // Minimal inline status bar above the prompt with proper transport icons (▶, ⏸, ⏭) and Login button
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (uiPlacement !== 'band' && uiPlacement !== 'both') {
      return next(e);
    }
    if (isUiHidden || !hasActiveTrack) {
      return next(e);
    }

    const { Box, Text, Button, Input } = $.ui.resolve(e);
    const theirs = await next(e);

    const modeBadge =
      controllerMode === 'mini'
        ? 'MINI'
        : controllerMode === 'side-panel'
          ? 'SIDEBAR'
          : 'POPUP';

    const topRow = Box({
      flexDirection: 'row',
      columnGap: 2,
      children: [
        Text({
          bold: true,
          color: isPlaying ? 'green' : 'cyan',
          children: ['SPOTIFY [' + modeBadge + ']']
        }),
        Text({
          wrap: 'truncate-end',
          children: [currentTrack.title + ' - ' + (currentTrack.artist || 'Spotify')]
        }),
        Button({
          key: 'mini-toggle-play',
          label: '▶',
          plain: true,
          onPress: async () => {
            const meta = await playSpotifyTarget($, currentTrack.id, screenPosition, controllerMode);
            $.ui.toast('Playing "' + meta.title + '" - ' + (meta.artist || 'Spotify'));
          }
        }),
        Button({
          key: 'mini-pause',
          label: '⏸',
          plain: true,
          dimColor: !isPlaying,
          onPress: async () => {
            isPlaying = false;
            await runNativePlayerCommand($, ['pause']);
            $.ui.invalidate('ui.render');
          }
        }),
        Button({
          key: 'mini-next',
          label: '⏭',
          plain: true,
          onPress: async () => {
            await stepPlaylist($, 1);
          }
        }),
        Button({
          key: 'mini-voice-search',
          label: isVoiceListening ? 'Listening...' : 'Voice',
          plain: true,
          onPress: async () => {
            await runVoiceSearch($, '');
          }
        }),
        Button({
          key: 'mini-toggle-drawer',
          label: controllerMode === 'side-panel' ? 'Mini' : 'Sidebar',
          plain: true,
          onPress: async () => {
            if (controllerMode === 'side-panel') {
              await setControllerConfiguration($, 'mini', 'top-right');
            } else {
              await setControllerConfiguration($, 'side-panel', 'right-side');
            }
          }
        }),
        Button({
          key: 'mini-toggle-popup',
          label: controllerMode === 'popup' ? 'Mini' : 'Popup',
          plain: true,
          onPress: async () => {
            if (controllerMode === 'popup') {
              await setControllerConfiguration($, 'mini', 'top-right');
            } else {
              await setControllerConfiguration($, 'popup', 'top-right');
            }
          }
        }),
        Button({
          key: 'mini-spotify-login',
          label: isLoggedIn ? 'Logged In' : 'Login',
          plain: true,
          onPress: async () => {
            await openSpotifyLogin($);
          }
        })
      ]
    });

    const searchRow = Input
      ? [
          Input({
            key: 'mini-search-input',
            label: 'Search',
            placeholder: 'Type song, artist, or Spotify URL and press Enter...',
            value: '',
            submitLabel: 'play',
            onSubmit: async (val) => {
              const target = val && val.trim() ? val.trim() : currentTrack.id;
              const meta = await playSpotifyTarget($, target, null, null);
              $.ui.toast('Playing "' + meta.title + '" - ' + (meta.artist || 'Spotify'));
            }
          })
        ]
      : [];

    const miniControllerBar = Box({
      borderStyle: 'round',
      borderColor: isPlaying ? 'green' : 'cyan',
      paddingX: 1,
      flexDirection: 'column',
      children: [topRow, ...searchRow]
    });

    return Box({
      flexDirection: 'column',
      children: [theirs, miniControllerBar]
    });
  });

  // Minimal Sidebar Player inside Claude Code: renders actual PNG album cover via Image component + proper transport icons
  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE_ID) {
      return next(e);
    }

    const { Box, Text, Button, Input, Image, Svg } = $.ui.resolve(e);

    const coverArt =
      e.surface === 'terminal' && Image
        ? Image({
            key: 'spotify-album-cover',
            source: {
              file: COVER_PNG_FILE_PATH,
              format: 'png',
              generation: coverGeneration
            },
            columns: 28,
            rows: 14,
            alt: 'Album cover for ' + currentTrack.title
          })
        : e.surface === 'desktop' && Svg
          ? Svg({
              alt: 'Album cover for ' + currentTrack.title,
              width: 120,
              height: 120,
              source: buildAlbumCoverSvg(currentTrack)
            })
          : Text({
              dimColor: true,
              children: ['[Album Cover]']
            });

    const controlsRow = Box({
      flexDirection: 'row',
      columnGap: 2,
      children: [
        Button({
          key: 'btn-prev-track',
          label: '⏮',
          plain: true,
          onPress: async () => {
            await stepPlaylist($, -1);
          }
        }),
        Button({
          key: 'btn-play-toggle',
          label: isPlaying ? '⏸' : '▶',
          plain: true,
          onPress: async () => {
            if (isPlaying) {
              isPlaying = false;
              await runNativePlayerCommand($, ['pause']);
              $.ui.invalidate('ui.render');
            } else {
              await playSpotifyTarget($, currentTrack.id, screenPosition, controllerMode);
            }
          }
        }),
        Button({
          key: 'btn-next-track',
          label: '⏭',
          plain: true,
          onPress: async () => {
            await stepPlaylist($, 1);
          }
        }),
        Button({
          key: 'btn-voice-search',
          label: isVoiceListening ? 'Listening...' : 'Voice',
          plain: true,
          onPress: async () => {
            await runVoiceSearch($, '');
          }
        }),
        Button({
          key: 'btn-spotify-login',
          label: isLoggedIn ? 'Logged In' : 'Login',
          plain: true,
          onPress: async () => {
            await openSpotifyLogin($);
          }
        })
      ]
    });

    const modeSwitchRow = Box({
      flexDirection: 'row',
      columnGap: 2,
      children: [
        Button({
          key: 'cfg-mini-controller',
          label: 'Mini Bar',
          plain: true,
          onPress: async () => {
            await setControllerConfiguration($, 'mini', 'top-right');
          }
        }),
        Button({
          key: 'cfg-popup-window',
          label: 'Popup Window',
          plain: true,
          onPress: async () => {
            await setControllerConfiguration($, 'popup', 'top-right');
          }
        }),
        Button({
          key: 'btn-stop-player',
          label: '■ Stop',
          plain: true,
          dimColor: !isPlaying,
          onPress: async () => {
            await stopPlayback($);
          }
        })
      ]
    });

    return Box({
      flexDirection: 'column',
      rowGap: 1,
      paddingX: 1,
      children: [
        coverArt,
        Box({
          flexDirection: 'column',
          children: [
            Text({
              bold: true,
              color: isPlaying ? 'green' : 'cyan',
              children: [currentTrack.title]
            }),
            Text({
              dimColor: true,
              children: [currentTrack.artist || 'Spotify']
            }),
            ...(lastVoiceTranscript
              ? [
                  Text({
                    dimColor: true,
                    children: ['Voice: "' + lastVoiceTranscript + '"']
                  })
                ]
              : [])
          ]
        }),
        controlsRow,
        Input({
          key: 'spotify-search-input',
          label: 'Search',
          placeholder: 'Song, artist, or Spotify URL...',
          value: '',
          submitLabel: 'play',
          onSubmit: async (value) => {
            const target = value && value.trim() ? value.trim() : currentTrack.id;
            await playSpotifyTarget($, target, null, null);
          }
        }),
        modeSwitchRow
      ]
    });
  });
}
