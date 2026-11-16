/**
 * 沙盒游戏启动器 · Host 端。
 *
 * 只做一件事：让 Web 页面点一下就能启动本机的 Godot 游戏。
 *
 * 接口（服务监听本机回环地址；每个请求再校验 Host / Origin，其他站点无法调用）：
 *   GET  /api/game-launcher/state    查询本插件启动的游戏是否仍在运行
 *   POST /api/game-launcher/launch   启动游戏，body: { mode?, ip? }
 *   POST /api/game-launcher/stop     停止本插件启动的游戏（整组进程）
 *
 * 设计取舍：
 * - detached + unref 启动：退出 DSH 后游戏窗口仍然保留；
 * - 不经过会话 / Agent：新会话里也能直接打开；
 * - 子进程输出写到 /tmp/dsh-game-launcher.log，启动失败时把日志尾巴一起返回。
 */
import { spawn } from 'node:child_process'
import { accessSync, closeSync, constants, existsSync, openSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const ROUTE = '/api/game-launcher'
const DEFAULT_GAME_DIR = '/Users/aaaa/PycharmProjects/jbw_first_game'
const LOG_PATH = '/tmp/dsh-game-launcher.log'
const MODES = new Set(['solo', 'menu', 'host', 'join', 'both', 'editor'])
const MODE_LABELS = {
  solo: '单机',
  menu: '联机菜单',
  host: '主机',
  join: '客户端',
  both: '双窗口',
  editor: '编辑器',
}
const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
}

/** 只有本机页面能调用：校验 Host 与 Fetch 元数据，且不返回 CORS 头。 */
function trustedRequest(request) {
  const origin = request.headers.origin
  if (origin) {
    try {
      if (new URL(origin).host !== request.headers.host) return false
    } catch {
      return false
    }
  }
  const site = request.headers['sec-fetch-site']
  if (site && site !== 'same-origin' && site !== 'none') return false
  return true
}

function send(response, status, body) {
  const text = JSON.stringify(body)
  response.writeHead(status, {
    ...JSON_HEADERS,
    'content-length': Buffer.byteLength(text),
  })
  response.end(text)
}

function failure(response, message, status = 500) {
  send(response, status, { ok: false, error: message })
}

function errorMessage(error) {
  if (error instanceof Error && error.message) return error.message
  return String(error)
}

async function readBody(request) {
  const chunks = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > 10_000) throw new Error('请求体过大')
    chunks.push(chunk)
  }
  return Buffer.concat(chunks).toString('utf8')
}

/** 读取日志尾部，供启动失败时一起返回。 */
function logTail(bytes = 600) {
  try {
    return readFileSync(LOG_PATH, 'utf8').slice(-bytes).trim()
  } catch {
    return ''
  }
}

/**
 * 游戏进程组是否还活着。
 * 启动时 detached 让脚本成为新进程组的组长，所以组号 = 启动时的 pid；
 * both 模式脚本会先退出，但两个 Godot 仍在同一组里，按组判断才准。
 */
function groupAlive(pgid) {
  if (typeof pgid !== 'number' || !Number.isSafeInteger(pgid) || pgid <= 1) return false
  try {
    process.kill(-pgid, 0)
    return true
  } catch {
    return false
  }
}

/** 给整个游戏进程组发信号；组已经不存在时返回 false。 */
function signalGroup(pgid, signal) {
  try {
    process.kill(-pgid, signal)
    return true
  } catch {
    return false
  }
}

async function waitForGroupGone(pgid, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (!groupAlive(pgid)) return true
    await new Promise(resolvePromise => setTimeout(resolvePromise, 100))
  }
  return !groupAlive(pgid)
}

/** 确认 run.sh 和 Godot 可执行文件都在；不在时给出可操作的中文原因。 */
function preflight(gameDir) {
  const script = join(gameDir, 'run.sh')
  if (!existsSync(script)) {
    throw new Error(`在 ${gameDir} 找不到 run.sh，请检查插件配置 gameDir`)
  }
  try {
    accessSync(script, constants.X_OK)
  } catch {
    throw new Error(`${script} 没有执行权限，请先运行 chmod +x run.sh`)
  }
  const godot = join(gameDir, 'tools/Godot.app/Contents/MacOS/Godot')
  if (!existsSync(godot)) {
    throw new Error(`找不到 Godot 引擎：${godot}（tools/Godot.app 可能被删掉了）`)
  }
  return { script, godot }
}

/**
 * 启动游戏，等一小段时间确认不是立刻失败。
 * @param {string} gameDir 游戏项目目录
 * @param {{ mode: string, ip?: string }} options 模式与 join 的 IP
 * @returns {Promise<{ pgid: number, mode: string }>}
 */
async function launch(gameDir, options) {
  const { script } = preflight(gameDir)
  const args = options.mode === 'join' ? ['join', options.ip || '127.0.0.1'] : [options.mode]

  const fd = openSync(LOG_PATH, 'a')
  let child
  try {
    child = spawn(script, args, {
      cwd: gameDir,
      detached: true,
      stdio: ['ignore', fd, fd],
      env: process.env,
    })
  } finally {
    closeSync(fd)
  }
  child.unref()
  // 600ms 之后再出现的启动错误也要有人接住，否则会成为未处理的 'error' 事件。
  child.on('error', () => {})

  // 立刻失败的常见原因：脚本语法错误、引擎缺失、端口被占用。等 600ms 抓到就给页面清楚的反馈。
  const earlyFailure = await new Promise(resolvePromise => {
    let settled = false
    const finish = value => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      child.off('error', onError)
      child.off('exit', onExit)
      resolvePromise(value)
    }
    const onError = error => finish(error)
    const onExit = (code, signal) => {
      if (code !== null && code !== 0) {
        finish(new Error(`启动脚本退出码 ${code}${signal ? `（${signal}）` : ''}`))
      }
      // 退出码 0 表示脚本自己完成了（both 模式会先起两个窗口再退出），不算失败。
    }
    const timer = setTimeout(() => finish(null), 600)
    timer.unref?.()
    child.on('error', onError)
    child.on('exit', onExit)
  })

  if (earlyFailure) {
    const tail = logTail()
    throw new Error(`${errorMessage(earlyFailure)}${tail ? `\n${tail}` : ''}`)
  }
  if (typeof child.pid !== 'number') throw new Error('无法获取游戏进程号')
  return { pgid: child.pid, mode: options.mode }
}

export const inject = ['webServer']

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {{ gameDir?: string, mode?: string }} [config]
 */
export function apply(ctx, config) {
  const settings = config ?? {}
  const gameDir = typeof settings.gameDir === 'string' && settings.gameDir.trim()
    ? resolve(settings.gameDir.trim())
    : DEFAULT_GAME_DIR
  const defaultMode = MODES.has(settings.mode) ? settings.mode : 'solo'

  /** 最近一次由本插件启动的游戏进程组；只在内存里，重启 DSH 后丢失。 */
  let lastLaunch = null

  const running = () => lastLaunch !== null && groupAlive(lastLaunch.pgid)

  const handler = async (request, response) => {
    if (!trustedRequest(request)) {
      failure(response, '拒绝来自其他站点的请求', 403)
      return
    }

    const pathname = new URL(request.url, 'http://127.0.0.1').pathname

    if (request.method === 'GET' && pathname === `${ROUTE}/state`) {
      send(response, 200, {
        ok: true,
        running: running(),
        mode: lastLaunch?.mode ?? null,
        pid: running() ? lastLaunch.pgid : null,
        gameDir,
        defaultMode,
        logPath: LOG_PATH,
      })
      return
    }

    if (request.method === 'POST' && pathname === `${ROUTE}/launch`) {
      let payload = {}
      try {
        payload = JSON.parse(await readBody(request) || '{}')
      } catch {
        failure(response, '请求格式不正确', 400)
        return
      }

      const mode = typeof payload?.mode === 'string' && payload.mode ? payload.mode : defaultMode
      if (!MODES.has(mode)) {
        failure(response, `不支持的模式「${mode}」，可用：${[...MODES].join('、')}`, 400)
        return
      }
      const ip = typeof payload?.ip === 'string' && payload.ip.trim() ? payload.ip.trim() : undefined
      if (mode === 'join' && ip !== undefined && !/^[0-9a-zA-Z.:_-]+$/.test(ip)) {
        failure(response, 'IP 地址格式不正确', 400)
        return
      }

      // 同一个插件只守住自己启动的进程；both 模式本来就要两个窗口，不拦。
      if (running() && mode !== 'both') {
        failure(response, `游戏已经在运行（进程组 ${lastLaunch.pgid}）——先停止游戏，或改用 both 模式`, 409)
        return
      }

      try {
        const started = await launch(gameDir, { mode, ip })
        lastLaunch = { pgid: started.pgid, mode, startedAt: Date.now() }
        send(response, 200, {
          ok: true,
          mode,
          label: MODE_LABELS[mode],
          pid: started.pgid,
          logPath: LOG_PATH,
        })
      } catch (error) {
        failure(response, `启动失败：${errorMessage(error)}`)
      }
      return
    }

    if (request.method === 'POST' && pathname === `${ROUTE}/stop`) {
      if (!running()) {
        failure(response, '游戏没有在运行（或不是由本插件启动的进程）', 409)
        return
      }
      const pgid = lastLaunch.pgid
      // 先礼后兵：SIGTERM 让 Godot 自己退出，4 秒还不走再 SIGKILL 整组。
      signalGroup(pgid, 'SIGTERM')
      let stopped = await waitForGroupGone(pgid, 4000)
      if (!stopped) {
        signalGroup(pgid, 'SIGKILL')
        stopped = await waitForGroupGone(pgid, 2000)
      }
      if (!stopped) {
        failure(response, `停止失败：进程组 ${pgid} 仍在运行`, 500)
        return
      }
      lastLaunch = null
      send(response, 200, { ok: true, stopped: true, pid: pgid })
      return
    }

    failure(response, '未找到该接口', 404)
  }

  ctx.effect(
    () => ctx.webServer.register({ kind: 'prefix', path: ROUTE, handler }),
    'game-launcher: local launch API',
  )
}
