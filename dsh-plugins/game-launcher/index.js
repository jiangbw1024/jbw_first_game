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
import { execFile, spawn } from 'node:child_process'
import { accessSync, closeSync, constants, existsSync, openSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const ROUTE = '/api/game-launcher'
const PS = '/bin/ps'
const DEFAULT_GAME_DIR = '/Users/aaaa/PycharmProjects/jbw_first_game'
const LOG_PATH = '/tmp/dsh-game-launcher.log'
// 这些模式名会原样作为 run.sh 的第一个参数。
// start = 开始页（单机 / 联机二选一），S13 之后它是默认入口；
// menu 是 S13 之前的旧名字，run.sh 里保留成 start 的别名。
const MODES = new Set(['start', 'solo', 'online', 'menu', 'host', 'join', 'both', 'editor'])
const MODE_LABELS = {
  start: '开始页',
  solo: '单机',
  online: '联机（先登录）',
  menu: '开始页（旧别名）',
  host: '主机',
  join: '客户端',
  both: '双窗口',
  editor: '编辑器',
}
// ★ 默认必须是 start，不能是 solo。
//   以前这里和 cordis.patch.yml 都写 solo，于是点「打开游戏」等于执行
//   `run.sh solo` —— 玩家根本没机会选单机还是联机，一开窗就已经站在丧尸堆里。
//   终端里 `./run.sh` 正常，是因为它走的正是 start，两边的默认值不一致。
const DEFAULT_MODE = 'start'
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

function pidAlive(pid) {
  if (typeof pid !== 'number' || !Number.isSafeInteger(pid) || pid <= 1) return false
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

/** 给单个进程发信号；进程已经不存在时返回 false。 */
function signalPid(pid, signal) {
  try {
    process.kill(pid, signal)
    return true
  } catch {
    return false
  }
}

async function waitForStopped(groups, pids, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  const anyAlive = () => groups.some(groupAlive) || pids.some(pidAlive)
  while (Date.now() < deadline) {
    if (!anyAlive()) return true
    await new Promise(resolvePromise => setTimeout(resolvePromise, 100))
  }
  return !anyAlive()
}

/**
 * 按项目路径扫描 Godot 进程（编辑器除外），用于发现从终端或 play.command 启动的游戏。
 * 只认本项目 tools/Godot.app 里的引擎，避免误伤其它 Godot 程序。
 * @param {string} gameDir 游戏项目目录
 * @returns {Promise<Array<{ pid: number, pgid: number }>>} 匹配到的 Godot 进程
 */
async function detectExternalProcesses(gameDir) {
  const binary = join(gameDir, 'tools/Godot.app/Contents/MacOS/Godot')
  const lines = await new Promise(resolvePromise => {
    execFile(
      PS,
      ['-ww', '-axo', 'pid=,pgid=,command='],
      { timeout: 3000, maxBuffer: 4 * 1024 * 1024, encoding: 'utf8' },
      (error, stdout) => resolvePromise(error ? [] : String(stdout).split('\n')),
    )
  })
  const processes = []
  for (const line of lines) {
    if (!line.includes(binary)) continue
    const match = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line)
    if (!match) continue
    const pid = Number(match[1])
    const pgid = Number(match[2])
    const command = match[3] ?? ''
    if (pid <= 1 || pgid <= 1) continue
    // 编辑器窗口不算"游戏"，避免一次停止把没保存的场景关掉。
    if (/(^|\s)(--editor|-e)(\s|$)/.test(command)) continue
    processes.push({ pid, pgid })
  }
  return processes
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
    // 这里的等待被请求 await 着，定时器保持引用，避免在没有其它事件的场景下提前结束进程。
    const timer = setTimeout(() => finish(null), 600)
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
  // 配置里没写或写了不认识的值 → 回默认（开始页）。
  // 不认识的模式不能"猜一个"，尤其不能猜 solo：猜错的代价是玩家直接被丢进游戏里。
  const defaultMode = MODES.has(settings.mode) ? settings.mode : DEFAULT_MODE

  /** 最近一次由本插件启动的游戏进程组；只在内存里，重启 DSH 后丢失。 */
  let lastLaunch = null
  /** 本进程自己的进程组，停止时永远跳过它。 */
  let ownGroup = null
  execFile(PS, ['-o', 'pgid=', '-p', String(process.pid)], { timeout: 3000, encoding: 'utf8' }, (error, stdout) => {
    if (!error) ownGroup = Number(String(stdout).trim()) || null
  })

  /**
   * 合并"本插件启动的"和"按项目路径扫描到的"游戏进程。
   * 自己启动的按进程组跟踪；扫描到的只记录单个 pid，停止时绝不向它的进程组发信号——
   * 终端里跑起来的游戏可能和用户 shell 同组，整组 SIGTERM 会误伤终端。
   */
  const findRunning = async () => {
    const groups = new Set()
    const pids = new Set()
    if (lastLaunch !== null && groupAlive(lastLaunch.pgid)) groups.add(lastLaunch.pgid)
    for (const { pid, pgid } of await detectExternalProcesses(gameDir)) {
      if (pgid === lastLaunch?.pgid) continue
      if (pgid === ownGroup || pid === process.pid) continue
      pids.add(pid)
    }
    return {
      groups: [...groups],
      pids: [...pids],
      count: groups.size + pids.size,
      source: groups.size === 0 && pids.size === 0 ? null : groups.size > 0 ? 'plugin' : 'external',
    }
  }

  const handler = async (request, response) => {
    if (!trustedRequest(request)) {
      failure(response, '拒绝来自其他站点的请求', 403)
      return
    }

    const pathname = new URL(request.url, 'http://127.0.0.1').pathname

    if (request.method === 'GET' && pathname === `${ROUTE}/state`) {
      const current = await findRunning()
      send(response, 200, {
        ok: true,
        running: current.count > 0,
        source: current.source,
        mode: lastLaunch?.mode ?? null,
        pid: current.groups[0] ?? current.pids[0] ?? null,
        groups: current.groups,
        pids: current.pids,
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

      // 本插件启动的、或按项目路径扫描到的游戏都算"在运行"；both 模式本来就要两个窗口，不拦。
      const current = await findRunning()
      if (current.count > 0 && mode !== 'both') {
        const where = [...current.groups.map(pgid => `进程组 ${pgid}`), ...current.pids.map(pid => `进程 ${pid}`)].join('、')
        failure(response, `游戏已经在运行（${where}）——先停止游戏，或改用 both 模式`, 409)
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
      const current = await findRunning()
      if (current.count === 0) {
        failure(response, '游戏没有在运行（没有找到本项目的 Godot 进程）', 409)
        return
      }
      // 先礼后兵：SIGTERM 让 Godot 自己退出，4 秒还不走再 SIGKILL。
      // 自己启动的按组杀（detached 新组，安全）；扫描到的只杀单个进程，不动进程组。
      for (const pgid of current.groups) signalGroup(pgid, 'SIGTERM')
      for (const pid of current.pids) signalPid(pid, 'SIGTERM')
      let stopped = await waitForStopped(current.groups, current.pids, 4000)
      if (!stopped) {
        for (const pgid of current.groups) {
          if (groupAlive(pgid)) signalGroup(pgid, 'SIGKILL')
        }
        for (const pid of current.pids) {
          if (pidAlive(pid)) signalPid(pid, 'SIGKILL')
        }
        stopped = await waitForStopped(current.groups, current.pids, 2000)
      }
      if (!stopped) {
        const survivors = [
          ...current.groups.filter(groupAlive).map(pgid => `进程组 ${pgid}`),
          ...current.pids.filter(pidAlive).map(pid => `进程 ${pid}`),
        ]
        failure(response, `停止失败：${survivors.join('、')} 仍在运行`, 500)
        return
      }
      lastLaunch = null
      send(response, 200, {
        ok: true,
        stopped: true,
        groups: current.groups,
        pids: current.pids,
        source: current.source,
      })
      return
    }

    failure(response, '未找到该接口', 404)
  }

  ctx.effect(
    () => ctx.webServer.register({ kind: 'prefix', path: ROUTE, handler }),
    'game-launcher: local launch API',
  )
}
