window.__ModuleLoader__.load({
  id: '@local/game-launcher',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const { useEffect, useRef, useState } = React

    const NS = 'gameLauncher'
    const LAUNCH_URL = '/api/game-launcher/launch'
    const STATE_URL = '/api/game-launcher/state'
    const POLL_MS = 5000
    const MODES = new Set(['solo', 'menu', 'host', 'join', 'both', 'editor'])

    /** 简体中文（键集基准）。 */
    const zh = {
      'section.title': '游戏',
      'section.hint': '本机 · Godot',
      'name': '沙盒游戏',
      'summary': '在应用托管里一键启动；窗口独立运行，退出 DSH 也不会关闭。',
      'log': '日志：/tmp/dsh-game-launcher.log',
      'status.running': '运行中',
      'status.stopped': '未运行',
      'status.unknown': '状态未知',
      'mode.solo': '单机',
      'mode.menu': '联机菜单',
      'mode.host': '主机',
      'mode.join': '客户端',
      'mode.both': '双窗口',
      'mode.editor': '编辑器',
      'launch': '打开游戏',
      'launching': '正在启动…',
      'launched': '游戏已启动',
      'alreadyRunning': '游戏已经在运行',
      'failed': '启动失败',
      'loadFailed': '无法读取游戏状态',
    }

    /** 英文。 */
    const en = {
      'section.title': 'Game',
      'section.hint': 'Local · Godot',
      'name': 'Sandbox game',
      'summary': 'Launch it from App hosting; the window keeps running after DSH quits.',
      'log': 'Log: /tmp/dsh-game-launcher.log',
      'status.running': 'Running',
      'status.stopped': 'Not running',
      'status.unknown': 'Unknown',
      'mode.solo': 'Solo',
      'mode.menu': 'Multiplayer menu',
      'mode.host': 'Host',
      'mode.join': 'Client',
      'mode.both': 'Two windows',
      'mode.editor': 'Editor',
      'launch': 'Open game',
      'launching': 'Launching…',
      'launched': 'Game launched',
      'alreadyRunning': 'The game is already running',
      'failed': 'Launch failed',
      'loadFailed': 'Unable to read game status',
    }

    // 与「应用托管」页面的卡片同一套尺寸与主题 token，保证并排时不突兀。
    const css = `
.gl-section { display: flex; flex-direction: column; gap: 12px; }
.gl-section-head { display: flex; align-items: baseline; gap: 10px; }
.gl-section-title { margin: 0; font-size: 14px; font-weight: 500; line-height: 20px; }
.gl-section-hint { font-size: 12px; line-height: 18px; color: var(--dsw-alias-label-secondary); }
.gl-card { border: 0.5px solid var(--dsw-alias-border-l1); border-radius: 12px; background: var(--dsw-alias-bg-layer-1); }
.gl-card-main { display: flex; gap: 14px; padding: 14px 16px; align-items: flex-start; }
.gl-dot { width: 8px; height: 8px; border-radius: 999px; background: var(--dsw-alias-state-idle-primary); margin-top: 6px; flex: none; }
.gl-dot[data-state='running'] { background: var(--dsw-alias-state-success-primary); }
.gl-dot[data-state='busy'] { background: var(--dsw-alias-state-warn-primary); }
.gl-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6px; }
.gl-title-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.gl-name { margin: 0; font-size: 14px; font-weight: 500; line-height: 20px; }
.gl-tag { font-size: 11px; line-height: 16px; color: var(--dsw-alias-label-secondary); border: 0.5px solid var(--dsw-alias-border-l1); border-radius: 4px; padding: 0 4px; }
.gl-tag[data-state='running'] { color: var(--dsw-alias-state-success-primary); border-color: var(--dsw-alias-state-success-primary); }
.gl-summary { margin: 0; font-size: 12.5px; line-height: 18px; color: var(--dsw-alias-label-secondary); }
.gl-meta { margin: 0; font-size: 11.5px; line-height: 16px; color: var(--dsw-alias-label-secondary); }
.gl-actions { display: flex; gap: 8px; flex: none; align-items: flex-start; flex-wrap: wrap; justify-content: flex-end; }
.gl-btn { appearance: none; display: inline-flex; align-items: center; justify-content: center; gap: 6px; height: 28px; padding: 0 12px; border-radius: 6px; border: 0.5px solid var(--dsw-alias-border-l2); background: transparent; color: var(--dsw-alias-label-primary); font: inherit; font-size: 13px; line-height: 1; cursor: pointer; white-space: nowrap; }
.gl-btn[data-variant='primary'] { color: var(--dsw-alias-brand-primary); border-color: var(--dsw-alias-brand-primary); }
.gl-btn:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 1px; }
.gl-btn:disabled { opacity: .5; cursor: default; }
@media (hover: hover) {
  .gl-btn:hover:not(:disabled) { background: var(--dsw-alias-bg-layer-2); }
}
.gl-notice { border-top: 0.5px solid var(--dsw-alias-border-l1); padding: 9px 16px; font-size: 12.5px; line-height: 18px; color: var(--dsw-alias-label-secondary); overflow-wrap: anywhere; }
.gl-notice[data-kind='ok'] { color: var(--dsw-alias-state-success-primary); }
.gl-notice[data-kind='error'] { color: var(--dsw-alias-state-error-primary); }
.gl-sr { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0; }
@media (max-width: 767px) {
  .gl-card-main { flex-wrap: wrap; }
  .gl-actions { width: 100%; justify-content: flex-start; }
}
`

    async function readJson(response) {
      const data = await response.json().catch(() => null)
      return { data, response }
    }

    async function fetchGameState() {
      const response = await fetch(STATE_URL, { cache: 'no-store' })
      const { data } = await readJson(response)
      if (!response.ok || !data || !data.ok) throw new Error(data && data.error ? data.error : `HTTP ${response.status}`)
      return data
    }

    function errorText(error) {
      return error instanceof Error && error.message ? error.message : String(error)
    }

    function GameCard({ t }) {
      const [game, setGame] = useState(null)
      const [busy, setBusy] = useState(false)
      const [notice, setNotice] = useState(null)
      const alive = useRef(true)

      const refresh = React.useCallback(async () => {
        try {
          const state = await fetchGameState()
          if (!alive.current) return
          setGame(state)
        } catch (failure) {
          if (!alive.current) return
          setNotice({ kind: 'error', text: `${t('loadFailed')}: ${errorText(failure)}` })
        }
      }, [t])

      useEffect(() => {
        alive.current = true
        void refresh()
        const timer = setInterval(() => {
          if (!document.hidden) void refresh()
        }, POLL_MS)
        const onVisible = () => {
          if (!document.hidden) void refresh()
        }
        document.addEventListener('visibilitychange', onVisible)
        return () => {
          alive.current = false
          clearInterval(timer)
          document.removeEventListener('visibilitychange', onVisible)
        }
      }, [refresh])

      useEffect(() => {
        if (!notice || notice.kind === 'error') return undefined
        const timer = setTimeout(() => setNotice(null), 4000)
        return () => clearTimeout(timer)
      }, [notice])

      const launch = async () => {
        if (busy || (game && game.running)) return
        setBusy(true)
        setNotice(null)
        try {
          const response = await fetch(LAUNCH_URL, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({}),
            credentials: 'same-origin',
            cache: 'no-store',
          })
          const { data } = await readJson(response)
          if (response.status === 409) {
            setNotice({ kind: 'info', text: t('alreadyRunning') })
            await refresh()
            return
          }
          if (!response.ok || !data || !data.ok) throw new Error(data && data.error ? data.error : `HTTP ${response.status}`)
          setNotice({ kind: 'ok', text: t('launched') })
          await refresh()
        } catch (failure) {
          setNotice({ kind: 'error', text: `${t('failed')}: ${errorText(failure)}` })
        } finally {
          if (alive.current) setBusy(false)
        }
      }

      const running = game !== null && game.running === true
      const mode = game !== null && typeof game.defaultMode === 'string' ? game.defaultMode : ''
      const modeLabel = MODES.has(mode) ? t(`mode.${mode}`) : ''
      const status = game === null ? t('status.unknown') : running ? t('status.running') : t('status.stopped')
      const label = busy ? t('launching') : running ? t('status.running') : t('launch')
      const dotState = running ? 'running' : game === null ? 'unknown' : 'stopped'

      return h(
        'section',
        { className: 'gl-section' },
        h('style', null, css),
        h(
          'div',
          { className: 'gl-section-head' },
          h('h2', { className: 'gl-section-title' }, t('section.title')),
          h('span', { className: 'gl-section-hint' }, t('section.hint')),
        ),
        h(
          'div',
          { className: 'gl-card' },
          h(
            'div',
            { className: 'gl-card-main' },
            h('span', { className: 'gl-dot', 'data-state': dotState, 'aria-hidden': 'true' }),
            h(
              'div',
              { className: 'gl-body' },
              h(
                'div',
                { className: 'gl-title-row' },
                h('h3', { className: 'gl-name' }, t('name')),
                modeLabel ? h('span', { className: 'gl-tag' }, modeLabel) : null,
                h('span', { className: 'gl-tag', 'data-state': running ? 'running' : 'stopped' }, status),
              ),
              h('p', { className: 'gl-summary' }, t('summary')),
              h('p', { className: 'gl-meta' }, t('log')),
            ),
            h(
              'div',
              { className: 'gl-actions' },
              h(
                'button',
                {
                  type: 'button',
                  className: 'gl-btn',
                  'data-variant': 'primary',
                  disabled: busy || running,
                  onClick: () => void launch(),
                },
                label,
              ),
            ),
          ),
          notice ? h('div', { className: 'gl-notice', 'data-kind': notice.kind }, notice.text) : null,
          h('span', { className: 'gl-sr', role: 'status', 'aria-live': 'polite' }, notice ? notice.text : ''),
        ),
      )
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'game-launcher: dictionaries')
        ctx.slots.inject('main.app-host.extra', () => ctx.slots.register({
          name: 'main.app-host.extra',
          id: 'game-launcher',
          order: 10,
          locale: NS,
        }, GameCard))
      },
    }
  },
})
