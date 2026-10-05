import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util, url as urlUtils } from '@kit.ArkTS';
import { http, vpnExtension, webSocket } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import * as nativeCore from 'libflclashcore.so';
import {
  AppSnapshot, ConnectionInfo, createInitialSnapshot, LogInfo, NodeInfo, Phase,
  Profile, ProxyGroup, ProxyMode, ThemeMode
} from '../model/Models';
import { PersistedState, PrivateStore, secureRandomHex } from '../storage/PrivateStore';

const BUNDLE_NAME: string = 'io.github.aaronkjiang.flclashhmos';
const VPN_ABILITY: string = 'FlClashVpnAbility';
const CONTROLLER_PORT: number = 9097;
const MAX_LOGS: number = 300;
const START_TIMEOUT_MS: number = 25000;
const STOP_TIMEOUT_MS: number = 12000;

interface RuntimeOptions {
  home: string;
  configPath: string;
  mode: ProxyMode;
  port: number;
  secret: string;
  selections: Record<string, string>;
  requestId: string;
}

interface RuntimeState {
  phase: Phase;
  error: string;
  profileId: string;
  startedAt: number;
  heartbeat: number;
  requestId: string;
}

interface Inspection {
  groups: ProxyGroup[];
  nodes: NodeInfo[];
  dynamicGroups: string[];
}

interface ModePatch {
  mode: ProxyMode;
}

interface NodeSelection {
  name: string;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function timeout<T>(promise: Promise<T>, milliseconds: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(message)), milliseconds);
    promise.then((value: T) => {
      clearTimeout(timer);
      resolve(value);
    }, (error: Error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function safeFileExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (_) {
    return false;
  }
}

function safeJson(path: string): Object | undefined {
  try {
    const value = JSON.parse(fs.readTextSync(path)) as Object | undefined;
    return value !== null && typeof value === 'object' ? value : undefined;
  } catch (_) {
    return undefined;
  }
}

function withSelection(previous: Record<string, string>, group: string, node: string): Record<string, string> {
  const selected: Record<string, string> = {};
  for (const name of Object.keys(previous)) {
    selected[name] = previous[name];
  }
  selected[group] = node;
  return selected;
}

export class AppService {
  private readonly store: PrivateStore;
  private readonly context: common.UIAbilityContext;
  private state: PersistedState | undefined = undefined;
  private snapshot: AppSnapshot = createInitialSnapshot();
  private listeners: Array<(snapshot: AppSnapshot) => void> = [];
  private mutationTail: Promise<void> = Promise.resolve();
  private pendingMutations: number = 0;
  private initialized: boolean = false;
  private disposed: boolean = false;
  private pollTimer: number = -1;
  private trafficReconnectTimer: number = -1;
  private logsReconnectTimer: number = -1;
  private trafficSocket: webSocket.WebSocket | undefined = undefined;
  private logsSocket: webSocket.WebSocket | undefined = undefined;
  private trafficMessageHandler: ((error: Error | undefined, data: string | ArrayBuffer) => void) | undefined = undefined;
  private logMessageHandler: ((error: Error | undefined, data: string | ArrayBuffer) => void) | undefined = undefined;
  private previousTrafficAt: number = 0;
  private previousUploadTotal: number = 0;
  private previousDownloadTotal: number = 0;
  private previousNodes: NodeInfo[] = [];
  private configuredNodes: NodeInfo[] = [];

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.store = new PrivateStore(context.filesDir);
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      this.disposed = false;
      this.beginMonitoring();
      return;
    }
    this.state = await this.store.load();
    this.initialized = true;
    this.disposed = false;
    this.snapshot.profiles = this.state.profiles;
    this.snapshot.activeProfileId = this.state.activeProfileId;
    this.snapshot.mode = this.state.mode;
    this.snapshot.theme = this.state.theme;
    this.snapshot.testUrl = this.state.testUrl;
    if (this.snapshot.profiles.every((profile: Profile) => profile.id !== this.snapshot.activeProfileId)) {
      this.snapshot.activeProfileId = '';
      this.state.activeProfileId = '';
      await this.store.save();
    }
    await this.reconcileRuntime();
    this.publish();
    this.beginMonitoring();
  }

  subscribe(listener: (snapshot: AppSnapshot) => void): () => void {
    this.listeners.push(listener);
    listener(this.cloneSnapshot());
    return (): void => {
      this.listeners = this.listeners.filter((item: (snapshot: AppSnapshot) => void) => item !== listener);
    };
  }

  dispose(): void {
    this.disposed = true;
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.trafficReconnectTimer !== -1) {
      clearTimeout(this.trafficReconnectTimer);
      this.trafficReconnectTimer = -1;
    }
    if (this.logsReconnectTimer !== -1) {
      clearTimeout(this.logsReconnectTimer);
      this.logsReconnectTimer = -1;
    }
    this.closeSocket(this.trafficSocket, 'message', this.trafficMessageHandler);
    this.closeSocket(this.logsSocket, 'message', this.logMessageHandler);
    this.trafficSocket = undefined;
    this.logsSocket = undefined;
    this.trafficMessageHandler = undefined;
    this.logMessageHandler = undefined;
  }

  importUrl(name: string, url: string): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      const profileName = this.validateProfileName(name);
      const subscriptionUrl = this.validateSubscriptionUrl(url);
      const yaml = await this.downloadProfile(subscriptionUrl);
      const inspection = await this.inspectYaml(yaml);
      await this.commitNewProfile(profileName, subscriptionUrl, yaml, inspection);
      this.snapshot.message = '配置已导入';
      this.publish();
    });
  }

  importFile(name: string, uri: string): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      const profileName = this.validateProfileName(name);
      let yaml: string;
      let inspection: Inspection;
      try {
        yaml = await this.readGrantedUri(uri);
        inspection = await this.inspectYaml(yaml);
      } catch (_) {
        throw new Error('无法读取或校验所选配置文件。');
      }
      await this.commitNewProfile(profileName, '', yaml, inspection);
      this.snapshot.message = '配置文件已导入';
      this.publish();
    });
  }

  updateProfile(id: string, grantedUri: string = ''): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      const profile = this.findProfile(id);
      if (profile.url.length === 0 && grantedUri.length === 0) {
        throw new Error('请通过文件选择器选择替换配置。');
      }
      let candidate: string;
      let candidateInspection: Inspection;
      try {
        candidate = profile.url.length > 0
          ? await this.downloadProfile(profile.url) : await this.readGrantedUri(grantedUri);
        candidateInspection = await this.inspectYaml(candidate);
      } catch (_) {
        throw new Error('配置更新失败，原配置保持不变。');
      }
      const wasRunning = this.snapshot.activeProfileId === id &&
        await this.hasActiveVpn();
      const previousYaml = this.store.readProfile(profile);
      const oldSnapshot = this.cloneSnapshot();
      if (wasRunning && oldSnapshot.phase === 'stopped') {
        oldSnapshot.phase = 'running';
      }
      const oldState = this.copyPersistedState();
      if (wasRunning) {
        await this.stopInternal();
      }
      const updated: Profile = {
        id: profile.id, name: profile.name, url: profile.url, path: profile.path,
        updatedAt: Date.now(), importedAt: profile.importedAt, usage: profile.usage
      };
      this.state!.profiles = this.state!.profiles.map((item: Profile) => item.id === id ? updated : item);
      this.state!.selections[id] = this.retainedSelections(id, candidateInspection);
      this.store.setState(this.state!);
      try {
        await this.store.updateProfileYaml(updated, candidate, async (): Promise<void> => {
          await this.store.save();
        });
      } catch (_) {
        this.state = oldState;
        this.store.setState(oldState);
        if (wasRunning) {
          await this.tryRestoreProfile(oldSnapshot, previousYaml);
        }
        throw new Error('配置更新未能保存，原配置已保留。');
      }
      this.snapshot.profiles = this.state!.profiles;
      if (!wasRunning && this.snapshot.activeProfileId === id) {
        this.snapshot.groups = this.applyOfflineSelections(candidateInspection.groups);
        this.snapshot.nodes = candidateInspection.nodes;
        this.configuredNodes = candidateInspection.nodes;
        this.previousNodes = candidateInspection.nodes;
      }
      if (wasRunning) {
        try {
          await this.startInternal();
        } catch (_) {
          this.state = oldState;
          this.store.setState(oldState);
          this.state!.profiles = this.state!.profiles.map((item: Profile) => item.id === id ? profile : item);
          this.store.setState(this.state!);
          try {
            await this.store.updateProfileYaml(profile, previousYaml, async (): Promise<void> => this.store.save());
          } catch (_) {
          }
          await this.tryRestoreProfile(oldSnapshot, previousYaml);
          throw new Error('更新配置无法启动，已回滚到原有配置。');
        }
      }
      this.snapshot.message = '配置已更新';
      this.publish();
    });
  }

  selectProfile(id: string): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      const profile = this.findProfile(id);
      let inspection: Inspection;
      try {
        inspection = await this.inspectYaml(this.store.readProfile(profile));
      } catch (_) {
        throw new Error('所选配置文件无法读取或校验，当前配置未更改。');
      }
      if (id === this.snapshot.activeProfileId) {
        if (this.snapshot.phase === 'stopped') {
          this.snapshot.groups = this.applyOfflineSelections(inspection.groups);
          this.snapshot.nodes = inspection.nodes;
          this.configuredNodes = inspection.nodes;
          this.previousNodes = inspection.nodes;
          this.publish();
        }
        return;
      }
      const wasRunning = await this.hasActiveVpn();
      const oldSnapshot = this.cloneSnapshot();
      if (wasRunning && oldSnapshot.phase === 'stopped') {
        oldSnapshot.phase = 'running';
      }
      const oldState = this.copyPersistedState();
      if (wasRunning) {
        await this.stopInternal();
      }
      this.state!.activeProfileId = id;
      this.store.setState(this.state!);
      try {
        await this.store.save();
      } catch (_) {
        this.state = oldState;
        this.store.setState(oldState);
        if (wasRunning) {
          await this.tryRestoreProfile(oldSnapshot);
        }
        throw new Error('无法保存配置选择；原配置保持不变。');
      }
      this.snapshot.activeProfileId = id;
      this.snapshot.groups = this.applyOfflineSelections(inspection.groups);
      this.snapshot.nodes = inspection.nodes;
      this.configuredNodes = inspection.nodes;
      this.previousNodes = inspection.nodes;
      this.snapshot.mode = this.state!.mode;
      if (wasRunning) {
        try {
          await this.startInternal();
        } catch (_) {
          this.state = oldState;
          this.store.setState(oldState);
          this.snapshot.activeProfileId = oldState.activeProfileId;
          this.snapshot.profiles = oldState.profiles;
          await this.tryRestoreProfile(oldSnapshot);
          throw new Error(this.snapshot.phase === 'running'
            ? '切换失败，已恢复之前的配置。' : '切换失败，未能恢复之前的 VPN。');
        }
      } else {
        this.snapshot.phase = 'stopped';
        this.snapshot.message = '已选择配置';
      }
      this.publish();
    });
  }

  deleteProfile(id: string): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      this.findProfile(id);
      const wasActive = this.snapshot.activeProfileId === id;
      const wasRunning = wasActive && await this.hasActiveVpn();
      const oldSnapshot = this.cloneSnapshot();
      if (wasRunning && oldSnapshot.phase === 'stopped') {
        oldSnapshot.phase = 'running';
      }
      if (wasRunning) {
        await this.stopInternal();
      }
      const oldState = this.copyPersistedState();
      this.state!.profiles = this.state!.profiles.filter((item: Profile) => item.id !== id);
      if (wasActive) {
        this.state!.activeProfileId = '';
      }
      const remaining: Record<string, Record<string, string>> = {};
      for (const profileId of Object.keys(this.state!.selections)) {
        if (profileId !== id) {
          remaining[profileId] = this.state!.selections[profileId];
        }
      }
      this.state!.selections = remaining;
      this.store.setState(this.state!);
      try {
        await this.store.save();
      } catch (_) {
        this.state = oldState;
        this.store.setState(oldState);
        if (wasRunning) {
          await this.tryRestoreProfile(oldSnapshot);
        }
        throw new Error('无法保存删除操作，配置仍然保留。');
      }
      try {
        this.store.removeProfileFile(id);
      } catch (_) {
        this.snapshot.profiles = this.state!.profiles;
        this.snapshot.activeProfileId = this.state!.activeProfileId;
        if (wasActive) {
          this.snapshot.groups = [];
          this.snapshot.nodes = [];
        }
        this.snapshot.message = '配置已移除，但无法清理本地文件';
        this.publish();
        throw new Error('配置已从列表移除，但无法清理本地文件。');
      }
      this.snapshot.profiles = this.state!.profiles;
      this.snapshot.activeProfileId = this.state!.activeProfileId;
      if (wasActive) {
        this.snapshot.groups = [];
        this.snapshot.nodes = [];
      }
      this.snapshot.message = '配置已删除';
      this.publish();
    });
  }

  renameProfile(id: string, name: string): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      const profile = this.findProfile(id);
      const updated: Profile = {
        id: profile.id, name: this.validateProfileName(name), url: profile.url, path: profile.path,
        updatedAt: profile.updatedAt, importedAt: profile.importedAt, usage: profile.usage
      };
      this.state!.profiles = this.state!.profiles.map((item: Profile) => item.id === id ? updated : item);
      this.store.setState(this.state!);
      try {
        await this.store.save();
      } catch (_) {
        this.state!.profiles = this.state!.profiles.map((item: Profile) => item.id === id ? profile : item);
        this.store.setState(this.state!);
        throw new Error('无法保存配置名称。');
      }
      this.snapshot.profiles = this.state!.profiles;
      this.publish();
    });
  }

  start(): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      await this.startInternal();
    });
  }

  stop(): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      await this.stopInternal();
    });
  }

  setMode(mode: ProxyMode): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      if (mode !== 'rule' && mode !== 'global' && mode !== 'direct') {
        throw new Error('代理模式无效。');
      }
      if (this.snapshot.phase === 'starting' || this.snapshot.phase === 'stopping') {
        throw new Error('请等待 VPN 状态转换完成后再更改代理模式。');
      }
      if (this.snapshot.phase === 'running') {
        await this.requireRunningController();
        const patch: ModePatch = { mode };
        await this.controllerRequest('/configs', 'PATCH', patch);
      }
      const old = this.state!.mode;
      this.state!.mode = mode;
      this.store.setState(this.state!);
      try {
        await this.store.save();
      } catch (_) {
        this.state!.mode = old;
        this.store.setState(this.state!);
        if (this.snapshot.phase === 'running') {
          try {
            const patch: ModePatch = { mode: old };
            await this.controllerRequest('/configs', 'PATCH', patch);
          } catch (_) {
            this.snapshot.mode = mode;
            this.publish();
          }
        }
        throw new Error('无法保存代理模式。');
      }
      this.snapshot.mode = mode;
      this.snapshot.message = '代理模式已更新';
      this.publish();
    });
  }

  selectNode(group: string, node: string): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      if (this.snapshot.phase === 'starting' || this.snapshot.phase === 'stopping') {
        throw new Error('请等待 VPN 状态转换完成后再切换节点。');
      }
      if (this.snapshot.phase === 'running') {
        await this.requireRunningController();
        const liveGroups = await this.fetchGroups();
        const liveGroup = liveGroups.find((item: ProxyGroup) => item.name === group);
        if (liveGroup === undefined || liveGroup.type.toLowerCase() !== 'selector') {
          throw new Error('该代理组不可手动选择。');
        }
        if (!liveGroup.all.includes(node)) {
          throw new Error('目标节点不属于所选代理组。');
        }
        const selection: NodeSelection = { name: node };
        await this.controllerRequest(`/proxies/${encodeURIComponent(group)}`, 'PUT', selection);
        const profileId = this.state!.activeProfileId;
        const previous = this.state!.selections[profileId] ?? {};
        this.state!.selections[profileId] = withSelection(previous, group, node);
        this.store.setState(this.state!);
        try {
          await this.store.save();
        } catch (_) {
          this.state!.selections[profileId] = previous;
          this.store.setState(this.state!);
          try {
            const selection: NodeSelection = { name: liveGroup.now };
            await this.controllerRequest(`/proxies/${encodeURIComponent(group)}`, 'PUT', selection);
          } catch (_) {
            this.snapshot.groups = await this.fetchGroups();
            this.publish();
          }
          throw new Error('选择已尝试但无法持久保存。');
        }
        this.snapshot.groups = await this.fetchGroups();
        this.snapshot.message = '代理节点已切换';
      } else {
        const local = this.snapshot.groups.find((item: ProxyGroup) => item.name === group);
        if (local === undefined || local.type.toLowerCase() !== 'selector' || !local.all.includes(node)) {
          throw new Error('该节点不是所选代理组的有效选项。');
        }
        const profileId = this.state!.activeProfileId;
        const previous = this.state!.selections[profileId] ?? {};
        this.state!.selections[profileId] = withSelection(previous, group, node);
        this.store.setState(this.state!);
        try {
          await this.store.save();
        } catch (_) {
          this.state!.selections[profileId] = previous;
          this.store.setState(this.state!);
          throw new Error('无法保存节点选择。');
        }
        this.snapshot.groups = this.snapshot.groups.map((item: ProxyGroup): ProxyGroup =>
          item.name === group ? { name: item.name, type: item.type, all: item.all, now: node } : item);
        this.snapshot.message = '节点选择将在 VPN 启动后应用';
      }
      this.publish();
    });
  }

  testNode(node: string): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      if (this.snapshot.phase !== 'running') {
        throw new Error('VPN 未运行，无法测试节点。');
      }
      await this.requireRunningController();
      if (!this.snapshot.nodes.some((item: NodeInfo) => item.name === node)) {
        throw new Error('找不到要测试的节点。');
      }
      const path = `/proxies/${encodeURIComponent(node)}/delay?url=${encodeURIComponent(this.snapshot.testUrl)}&timeout=5000`;
      let latency: number;
      try {
        const result = await this.controllerRequest(path, 'GET', undefined, 7000);
        const parsed = JSON.parse(result) as Record<string, number>;
        latency = Number(parsed.delay);
        if (!Number.isFinite(latency) || latency < 0) {
          throw new Error('latency');
        }
      } catch (_) {
        throw new Error('节点延迟测试失败，请检查节点及测试地址。');
      }
      this.snapshot.nodes = this.snapshot.nodes.map((item: NodeInfo): NodeInfo =>
        item.name === node ? { name: item.name, type: item.type, delay: latency } : item);
      this.previousNodes = this.snapshot.nodes;
      this.snapshot.message = '节点延迟测试完成';
      this.publish();
    });
  }

  closeConnection(id: string): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      await this.requireRunningController();
      await this.controllerRequest(`/connections/${encodeURIComponent(id)}`, 'DELETE');
      await this.refreshControllerData();
    });
  }

  closeAllConnections(): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      await this.requireRunningController();
      await this.controllerRequest('/connections', 'DELETE');
      await this.refreshControllerData();
    });
  }

  setTheme(theme: ThemeMode): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      if (theme !== 'system' && theme !== 'light' && theme !== 'dark') {
        throw new Error('主题设置无效。');
      }
      const previous = this.state!.theme;
      this.state!.theme = theme;
      this.store.setState(this.state!);
      try {
        await this.store.save();
      } catch (_) {
        this.state!.theme = previous;
        this.store.setState(this.state!);
        throw new Error('无法保存主题设置。');
      }
      this.snapshot.theme = theme;
      this.publish();
    });
  }

  setTestUrl(url: string): Promise<void> {
    return this.serialize(async (): Promise<void> => {
      this.requireInitialized();
      let parsed: urlUtils.URL;
      try {
        parsed = new urlUtils.URL(url.trim());
      } catch (_) {
        throw new Error('测试地址必须是有效的 HTTPS URL。');
      }
      if (parsed.protocol !== 'https:' || parsed.username.length > 0 || parsed.password.length > 0) {
        throw new Error('测试地址必须是有效的 HTTPS URL。');
      }
      const previous = this.state!.testUrl;
      this.state!.testUrl = parsed.toString();
      this.store.setState(this.state!);
      try {
        await this.store.save();
      } catch (_) {
        this.state!.testUrl = previous;
        this.store.setState(this.state!);
        throw new Error('无法保存测试地址。');
      }
      this.snapshot.testUrl = this.state!.testUrl;
      this.publish();
    });
  }

  clearLogs(): void {
    this.snapshot.logs = [];
    this.publish();
  }

  private serialize<T>(work: () => Promise<T>): Promise<T> {
    this.pendingMutations += 1;
    const result = this.mutationTail.then(async (): Promise<T> => {
      try {
        return await work();
      } finally {
        this.pendingMutations -= 1;
      }
    });
    this.mutationTail = result.then((): void => undefined, (): void => undefined);
    return result;
  }

  private async loadActiveProfileInspection(): Promise<void> {
    if (this.state === undefined) {
      return;
    }
    const active = this.state.profiles.find((profile: Profile) => profile.id === this.state!.activeProfileId);
    if (active === undefined) {
      this.configuredNodes = [];
      this.previousNodes = [];
      this.snapshot.groups = [];
      this.snapshot.nodes = [];
      return;
    }
    try {
      const inspection = await this.inspectYaml(this.store.readProfile(active));
      this.snapshot.groups = this.applyOfflineSelections(inspection.groups);
      this.snapshot.nodes = inspection.nodes;
      this.configuredNodes = inspection.nodes;
      this.previousNodes = inspection.nodes;
    } catch (_) {
      if (this.snapshot.phase !== 'running' && this.snapshot.phase !== 'failed') {
        this.snapshot.message = '当前配置文件无法读取或校验';
      }
    }
  }
  private async reconcileRuntime(): Promise<void> {
    const runtime = this.readRuntimeState();
    const ready = await this.controllerIsReady();
    if (ready && runtime !== undefined && runtime.phase === 'running' &&
      runtime.profileId === this.state!.activeProfileId) {
      this.snapshot.phase = 'running';
      this.snapshot.message = 'VPN 正在运行';
      this.snapshot.startedAt = runtime !== undefined ? runtime.startedAt : 0;
      await this.loadActiveProfileInspection();
      await this.refreshControllerData();
      return;
    }
    if (runtime !== undefined && runtime.phase === 'starting' && Date.now() - runtime.heartbeat < 15000) {
      this.snapshot.phase = 'starting';
      this.snapshot.message = 'VPN 正在启动';
      return;
    }
    if (runtime !== undefined && runtime.phase === 'stopping' && Date.now() - runtime.heartbeat < 15000) {
      this.snapshot.phase = 'stopping';
      this.snapshot.message = 'VPN 正在停止';
      return;
    }
    this.snapshot.phase = ready || (runtime !== undefined && runtime.phase === 'failed') ? 'failed' : 'stopped';
    this.snapshot.message = ready ? '核心仍可访问，但 VPN 状态未获确认，请停止后重试。' :
      runtime !== undefined && runtime.phase === 'failed'
        ? (runtime.error.length > 0 ? runtime.error : 'VPN 启动失败') : 'VPN 已停止';
    this.snapshot.startedAt = 0;
    await this.loadActiveProfileInspection();
  }

  private beginMonitoring(): void {
    if (this.disposed) {
      return;
    }
    if (this.pollTimer === -1) {
      this.pollTimer = setInterval((): void => {
        void this.monitorRuntime();
      }, 2500);
    }
    if (this.snapshot.phase === 'running') {
      void this.connectTelemetry('traffic');
      void this.connectTelemetry('logs');
      void this.refreshControllerData();
    }
  }

  private async monitorRuntime(): Promise<void> {
    if (this.disposed || (this.pendingMutations > 0 &&
      (this.snapshot.phase === 'starting' || this.snapshot.phase === 'stopping'))) {
      return;
    }
    const runtime = this.readRuntimeState();
    const ready = await this.controllerIsReady();
    if (this.pendingMutations > 0 &&
      (this.snapshot.phase === 'starting' || this.snapshot.phase === 'stopping')) {
      return;
    }
    if ((this.snapshot.phase === 'starting' || this.snapshot.phase === 'stopping') &&
      (runtime === undefined || Date.now() - runtime.heartbeat >= 15000)) {
      this.snapshot.phase = 'failed';
      this.snapshot.message = 'VPN 状态确认超时，可以重新启动。';
      this.snapshot.startedAt = 0;
      this.snapshot.uploadRate = 0;
      this.snapshot.downloadRate = 0;
      this.closeTelemetry();
      this.publish();
      return;
    }
    if (this.snapshot.phase === 'stopping') {
      if (!ready && runtime !== undefined && runtime.phase === 'stopped') {
        this.snapshot.phase = 'stopped';
        this.snapshot.message = 'VPN 已停止';
        this.snapshot.startedAt = 0;
        this.publish();
      }
      return;
    }
    if (ready && runtime !== undefined && runtime.phase === 'running' &&
      runtime.profileId === this.state!.activeProfileId) {
      if (this.snapshot.phase !== 'running') {
        this.snapshot.phase = 'running';
        this.snapshot.message = 'VPN 正在运行';
        this.snapshot.startedAt = runtime !== undefined ? runtime.startedAt : 0;
        await this.loadActiveProfileInspection();
        this.publish();
        void this.connectTelemetry('traffic');
        void this.connectTelemetry('logs');
      }
      await this.refreshControllerData();
      return;
    }
    if (runtime !== undefined && Date.now() - runtime.heartbeat < 15000 &&
      (runtime.phase === 'starting' || runtime.phase === 'stopping')) {
      this.snapshot.phase = runtime.phase;
      this.snapshot.message = runtime.phase === 'starting' ? 'VPN 正在启动' : 'VPN 正在停止';
      this.publish();
      return;
    }
    if (ready) {
      this.snapshot.phase = 'failed';
      this.snapshot.message = '核心仍可访问，但 VPN 状态未获确认，请停止后重试。';
      this.closeTelemetry();
      this.publish();
      return;
    }
    if (this.snapshot.phase === 'starting' && runtime !== undefined && runtime.phase === 'failed') {
      this.snapshot.phase = 'failed';
      this.snapshot.message = runtime.error.length > 0 ? runtime.error : 'VPN 启动失败';
      this.snapshot.startedAt = 0;
      this.publish();
      return;
    }
    if (this.snapshot.phase === 'running') {
      this.snapshot.phase = runtime !== undefined && runtime.phase === 'stopped' ? 'stopped' : 'failed';
      this.snapshot.message = runtime !== undefined && runtime.phase === 'failed' && runtime.error.length > 0
        ? runtime.error : 'VPN 核心连接已断开';
      this.snapshot.startedAt = 0;
      this.snapshot.uploadRate = 0;
      this.snapshot.downloadRate = 0;
      this.previousTrafficAt = 0;
      this.closeTelemetry();
      this.publish();
    } else if (this.snapshot.phase === 'starting' && runtime !== undefined && runtime.phase === 'stopped') {
      this.snapshot.phase = 'stopped';
      this.snapshot.message = 'VPN 已停止';
      this.snapshot.startedAt = 0;
      this.publish();
    }
  }

  private async startInternal(): Promise<void> {
    if (this.state!.activeProfileId.length === 0) {
      throw new Error('请先导入并选择一个配置，再启动 VPN。');
    }
    if (await this.controllerIsReady()) {
      if (this.snapshot.phase === 'running') { return; }
      await this.stopInternal();
    }
    const profile = this.findProfile(this.state!.activeProfileId);
    let yaml: string;
    try {
      yaml = this.store.readProfile(profile);
      const inspection = await this.inspectYaml(yaml);
      this.snapshot.groups = this.applyOfflineSelections(inspection.groups);
      this.snapshot.nodes = inspection.nodes;
      this.configuredNodes = inspection.nodes;
      this.previousNodes = inspection.nodes;
    } catch (_) {
      throw new Error('当前配置文件无法读取或校验。');
    }
    const requestId = await secureRandomHex(16);
    this.snapshot.phase = 'starting';
    this.snapshot.message = '正在启动 VPN';
    this.snapshot.startedAt = 0;
    this.publish();
    const runtimeOptions: RuntimeOptions = {
      home: this.store.home,
      configPath: profile.path,
      mode: this.state!.mode,
      port: CONTROLLER_PORT,
      secret: this.state!.secret,
      selections: this.state!.selections[profile.id] ?? {},
      requestId
    };
    try {
      this.writePrivateAtomic(`${this.context.filesDir}/runtime-options.json`, JSON.stringify(runtimeOptions));
      await timeout(vpnExtension.startVpnExtensionAbility({
        bundleName: BUNDLE_NAME,
        abilityName: VPN_ABILITY
      }), 8000, '启动请求超时');
    } catch (_) {
      try {
        await timeout(vpnExtension.stopVpnExtensionAbility({
          bundleName: BUNDLE_NAME,
          abilityName: VPN_ABILITY
        }), 5000, '停止请求超时');
      } catch (_) {
      }
      this.snapshot.phase = 'failed';
      this.snapshot.message = '无法启动 VPN 扩展，请检查系统授权和运行状态。';
      this.snapshot.startedAt = 0;
      this.publish();
      throw new Error(this.snapshot.message);
    }
    const ready = await this.waitForStart(profile.id, requestId);
    if (!ready) {
      const failedRuntime = this.readRuntimeState();
      const failure = failedRuntime !== undefined && failedRuntime.requestId === requestId
        ? failedRuntime.error : '';
      try {
        await timeout(vpnExtension.stopVpnExtensionAbility({
          bundleName: BUNDLE_NAME,
          abilityName: VPN_ABILITY
        }), 5000, '停止请求超时');
      } catch (_) {
      }
      this.snapshot.phase = 'failed';
      this.snapshot.message = failure.length > 0 ? failure : 'VPN 核心未能在规定时间内就绪。';
      this.snapshot.startedAt = 0;
      this.publish();
      throw new Error(this.snapshot.message);
    }
    const runtime = this.readRuntimeState();
    this.snapshot.phase = 'running';
    this.snapshot.message = 'VPN 正在运行';
    this.snapshot.startedAt = runtime !== undefined ? runtime.startedAt : Date.now();
    this.snapshot.mode = this.state!.mode;
    this.snapshot.profiles = this.state!.profiles;
    this.snapshot.activeProfileId = profile.id;
    await this.refreshControllerData();
    this.publish();
    this.beginMonitoring();
  }

  private async waitForStart(profileId: string, requestId: string): Promise<boolean> {
    const end = Date.now() + START_TIMEOUT_MS;
    while (Date.now() < end) {
      const state = this.readRuntimeState();
      if (state !== undefined && state.requestId === requestId && state.phase === 'failed') {
        return false;
      }
      if (state !== undefined && state.requestId === requestId && state.phase === 'running' && state.profileId === profileId &&
        await this.controllerIsReady()) {
        return true;
      }
      await delay(350);
    }
    return false;
  }

  private async stopInternal(): Promise<void> {
    const initialRuntime = this.readRuntimeState();
    if (this.snapshot.phase === 'stopped' && !(await this.controllerIsReady()) &&
      (initialRuntime === undefined || initialRuntime.phase === 'stopped')) {
      this.closeTelemetry();
      return;
    }
    const requestId = await secureRandomHex(16);
    this.snapshot.phase = 'stopping';
    this.snapshot.message = '正在停止 VPN';
    this.publish();
    try {
      // Acknowledge OS interface destruction while the extension context is alive.
      // onDestroy cannot reliably finish an asynchronous destroy callback.
      await timeout(vpnExtension.startVpnExtensionAbility({
        bundleName: BUNDLE_NAME,
        abilityName: VPN_ABILITY,
        parameters: { action: 'stop', requestId }
      }), 8000, '停止请求超时');
      const end = Date.now() + STOP_TIMEOUT_MS;
      let acknowledged = false;
      while (Date.now() < end) {
        const runtime = this.readRuntimeState();
        const ready = await this.controllerIsReady();
        if (!ready && runtime !== undefined && runtime.requestId === requestId && runtime.phase === 'stopped') {
          acknowledged = true;
          break;
        }
        if (runtime !== undefined && runtime.requestId === requestId && runtime.phase === 'failed') {
          throw new Error(runtime.error || 'VPN 接口清理失败。');
        }
        await delay(300);
      }
      if (!acknowledged) {
        throw new Error('未收到 VPN 停止确认，运行状态无法确认。');
      }
      await timeout(vpnExtension.stopVpnExtensionAbility({
        bundleName: BUNDLE_NAME,
        abilityName: VPN_ABILITY
      }), 8000, 'VPN 扩展终止请求超时');
    } catch (error) {
      this.snapshot.phase = 'failed';
      this.snapshot.message = this.sanitizeLog((error as Error).message || 'VPN 停止失败。');
      this.publish();
      throw new Error(this.snapshot.message);
    }
    this.snapshot.phase = 'stopped';
    this.snapshot.message = 'VPN 已停止';
    this.snapshot.startedAt = 0;
    this.snapshot.uploadRate = 0;
    this.snapshot.downloadRate = 0;
    this.closeTelemetry();
    this.publish();
  }

  private async tryRestoreProfile(oldSnapshot: AppSnapshot, oldYaml?: string): Promise<void> {
    if (await this.hasActiveVpn()) {
      try {
        await this.stopInternal();
      } catch (_) {
        this.snapshot.phase = 'failed';
        this.snapshot.message = '当前 VPN 未确认停止，无法恢复之前的配置。';
        this.publish();
        return;
      }
    }
    if (oldYaml !== undefined && oldSnapshot.activeProfileId.length > 0) {
      const oldProfile = this.state!.profiles.find((item: Profile) => item.id === oldSnapshot.activeProfileId);
      if (oldProfile !== undefined) {
        try {
          this.store.writeProfileAtomic(oldProfile.id, oldYaml);
        } catch (_) {
        }
      }
    }
    this.state!.activeProfileId = oldSnapshot.activeProfileId;
    this.store.setState(this.state!);
    try {
      await this.store.save();
    } catch (_) {
    }
    this.snapshot.activeProfileId = oldSnapshot.activeProfileId;
    this.snapshot.profiles = this.state!.profiles;
    if (oldSnapshot.phase !== 'stopped') {
      try {
        await this.startInternal();
        this.snapshot.message = '已恢复之前的配置';
      } catch (_) {
        this.snapshot.phase = 'failed';
        this.snapshot.startedAt = 0;
      }
    } else {
      this.snapshot.phase = oldSnapshot.phase;
      this.snapshot.groups = oldSnapshot.groups;
      this.snapshot.nodes = oldSnapshot.nodes;
      this.snapshot.startedAt = oldSnapshot.startedAt;
    }
    this.publish();
  }

  private async commitNewProfile(name: string, url: string, yaml: string, inspection: Inspection): Promise<void> {
    const id = await this.store.createProfileId();
    const now = Date.now();
    const profile: Profile = {
      id,
      name,
      url,
      path: this.store.profilePath(id),
      updatedAt: now,
      importedAt: now,
      usage: ''
    };
    this.store.writeProfileAtomic(id, yaml);
    const oldState = this.copyPersistedState();
    this.state!.profiles = [...this.state!.profiles, profile];
    if (this.state!.activeProfileId.length === 0) {
      this.state!.activeProfileId = id;
    }
    this.store.setState(this.state!);
    try {
      await this.store.save();
    } catch (_) {
      this.state = oldState;
      this.store.setState(oldState);
      this.store.removeProfileFile(id);
      throw new Error('无法保存配置索引。');
    }
    this.snapshot.profiles = this.state!.profiles;
    if (this.snapshot.activeProfileId.length === 0) {
      this.snapshot.activeProfileId = id;
      this.snapshot.groups = this.applyOfflineSelections(inspection.groups);
      this.snapshot.nodes = inspection.nodes;
      this.configuredNodes = inspection.nodes;
      this.previousNodes = inspection.nodes;
    }
  }

  private async downloadProfile(url: string): Promise<string> {
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Clash.Meta/v1.19.31' },
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: 15000,
        readTimeout: 25000,
        maxLimit: 20 * 1024 * 1024
      });
      if (response.responseCode < 200 || response.responseCode >= 300 || typeof response.result !== 'string') {
        throw new Error(`订阅下载返回 HTTP ${response.responseCode}，或响应不是文本。`);
      }
      if (response.result.length === 0) {
        throw new Error('订阅响应为空。');
      }
      return response.result;
    } catch (error) {
      const failure = error as BusinessError;
      if (typeof failure.code === 'number') {
        throw new Error(`订阅网络请求失败（错误代码 ${failure.code}）。`);
      }
      throw error as Error;
    } finally {
      request.destroy();
    }
  }

  private async readGrantedUri(uri: string): Promise<string> {
    if (uri.length === 0) {
      throw new Error('uri');
    }
    const stat = fs.statSync(uri);
    if (stat.size <= 0 || stat.size > 20 * 1024 * 1024) {
      throw new Error('size');
    }
    const file = await fs.open(uri);
    try {
      const buffer = new Uint8Array(stat.size);
      const chunk = new Uint8Array(Math.min(64 * 1024, stat.size));
      let totalRead = 0;
      while (totalRead < stat.size) {
        const length = Math.min(chunk.length, stat.size - totalRead);
        const read = fs.readSync(file.fd, chunk.buffer, { length });
        if (read <= 0) {
          throw new Error('read');
        }
        buffer.set(chunk.subarray(0, read), totalRead);
        totalRead += read;
      }
      return util.TextDecoder.create('utf-8', { fatal: true }).decode(buffer);
    } finally {
      fs.closeSync(file);
    }
  }

  private async inspectYaml(yaml: string): Promise<Inspection> {
    let value: string;
    try {
      value = await nativeCore.inspect(yaml);
    } catch (_) {
      throw new Error('配置解析失败');
    }
    let parsed: Inspection;
    try {
      parsed = JSON.parse(value) as Inspection;
    } catch (_) {
      throw new Error('配置解析失败');
    }
    if (!Array.isArray(parsed.groups) || !Array.isArray(parsed.nodes) || !Array.isArray(parsed.dynamicGroups)) {
      throw new Error('配置解析失败');
    }
    return {
      groups: parsed.groups.map((item: ProxyGroup): ProxyGroup => ({
        name: item.name,
        type: item.type,
        all: Array.isArray(item.all) ? item.all : [],
        now: item.now ?? ''
      })),
      nodes: parsed.nodes.map((item: NodeInfo): NodeInfo => ({
        name: item.name,
        type: item.type,
        delay: typeof item.delay === 'number' ? item.delay : -1
      })),
      dynamicGroups: parsed.dynamicGroups
    };
  }

  private validateProfileName(name: string): string {
    const clean = name.trim();
    if (clean.length === 0 || clean.length > 80) {
      throw new Error('配置名称必须为 1 到 80 个字符。');
    }
    return clean;
  }

  private validateSubscriptionUrl(url: string): string {
    let parsed: urlUtils.URL;
    try {
      parsed = new urlUtils.URL(url.trim());
    } catch (_) {
      throw new Error('请输入有效的订阅地址。');
    }
    if ((parsed.protocol !== 'https:' && parsed.protocol !== 'http:') || parsed.hostname.length === 0) {
      throw new Error('请输入有效的 HTTP 或 HTTPS 订阅地址。');
    }
    return parsed.toString();
  }

  private findProfile(id: string): Profile {
    const profile = this.state!.profiles.find((item: Profile) => item.id === id);
    if (profile === undefined) {
      throw new Error('找不到指定配置。');
    }
    return profile;
  }

  private requireInitialized(): void {
    if (!this.initialized || this.state === undefined) {
      throw new Error('服务尚未初始化。');
    }
  }

  private async controllerRequest(path: string, method: rcp.HttpMethod,
    body?: Object, requestTimeout: number = 5000): Promise<string> {
    const configuration: rcp.Configuration = {
      transfer: {
        autoRedirect: false,
        timeout: { connectMs: requestTimeout, transferMs: requestTimeout }
      }
    };
    const session = rcp.createSession({ requestConfiguration: configuration });
    try {
      const headers: rcp.RequestHeaders = {
        Authorization: `Bearer ${this.state!.secret}`,
        'Content-Type': 'application/json'
      };
      const request = new rcp.Request(`http://127.0.0.1:${CONTROLLER_PORT}${path}`, method, headers,
        body === undefined ? undefined : JSON.stringify(body));
      const response = await session.fetch(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new Error(`controller-${response.statusCode}`);
      }
      return response.toString() ?? '';
    } finally {
      session.close();
    }
  }


  private async hasActiveVpn(): Promise<boolean> {
    if (await this.controllerIsReady()) { return true; }
    const runtime = this.readRuntimeState();
    return runtime !== undefined && Date.now() - runtime.heartbeat < 15000 &&
      (runtime.phase === 'starting' || runtime.phase === 'running' || runtime.phase === 'stopping');
  }

  private async controllerIsReady(): Promise<boolean> {
    try {
      await this.controllerRequest('/version', 'GET', undefined, 1500);
      return true;
    } catch (_) {
      return false;
    }
  }

  private async requireRunningController(): Promise<void> {
    if (this.snapshot.phase !== 'running' || !(await this.controllerIsReady())) {
      this.snapshot.phase = 'failed';
      this.snapshot.message = 'VPN 控制器不可用，操作未完成。';
      this.snapshot.startedAt = 0;
      this.publish();
      throw new Error(this.snapshot.message);
    }
  }

  private async refreshControllerData(): Promise<void> {
    if (this.disposed || this.snapshot.phase !== 'running') {
      return;
    }
    try {
      const responses: string[] = await Promise.all([
        this.controllerRequest('/proxies', 'GET'),
        this.controllerRequest('/connections', 'GET')
      ]);
      const proxyData = JSON.parse(responses[0]) as Record<string, Object>;
      const connectionData = JSON.parse(responses[1]) as Record<string, Object>;
      this.snapshot.groups = this.mapLiveGroups(proxyData.proxies as Record<string, Object>);
      this.snapshot.nodes = this.mapLiveNodes(proxyData.proxies as Record<string, Object>, this.snapshot.groups);
      this.snapshot.connections = this.mapConnections(connectionData.connections as Array<Object>);
      const upload = Number(connectionData.uploadTotal);
      const download = Number(connectionData.downloadTotal);
      if (Number.isFinite(upload) && Number.isFinite(download)) {
        this.updateTrafficTotals(upload, download, Date.now());
      }
      this.publish();
    } catch (_) {
      if (await this.controllerIsReady()) {
        this.snapshot.message = '控制器数据暂时不可用';
        this.publish();
      }
    }
  }

  private async fetchGroups(): Promise<ProxyGroup[]> {
    const result = await this.controllerRequest('/proxies', 'GET');
    const data = JSON.parse(result) as Record<string, Object>;
    return this.mapLiveGroups(data.proxies as Record<string, Object>);
  }

  private mapLiveGroups(proxies: Record<string, Object>): ProxyGroup[] {
    const groups: ProxyGroup[] = [];
    if (proxies === undefined || proxies === null) {
      return groups;
    }
    for (const name of Object.keys(proxies)) {
      const raw = proxies[name] as Record<string, Object>;
      if (Array.isArray(raw.all)) {
        groups.push({
          name,
          type: String(raw.type ?? 'Unknown'),
          all: (raw.all as Array<string>).map((node: string) => String(node)),
          now: String(raw.now ?? '')
        });
      }
    }
    return groups;
  }

  private mapLiveNodes(proxies: Record<string, Object>, groups: ProxyGroup[]): NodeInfo[] {
    const names: Record<string, boolean> = {};
    const nodes: NodeInfo[] = [];
    const previousByName: Record<string, NodeInfo> = {};
    this.previousNodes.forEach((node: NodeInfo) => previousByName[node.name] = node);
    this.configuredNodes.forEach((node: NodeInfo) => names[node.name] = true);
    groups.forEach((group: ProxyGroup) => group.all.forEach((name: string) => names[name] = true));
    for (const name of Object.keys(names)) {
      const raw = proxies[name] as Record<string, Object> | undefined;
      const old = previousByName[name];
      const history = raw !== undefined && Array.isArray(raw.history) ? raw.history as Array<Record<string, Object>> : [];
      const latest = history.length > 0 ? Number(history[history.length - 1].delay) : -1;
      nodes.push({
        name,
        type: raw !== undefined ? String(raw.type ?? 'Unknown') : old !== undefined ? old.type : 'Unknown',
        delay: Number.isFinite(latest) && latest >= 0 ? latest : old !== undefined ? old.delay : -1
      });
    }
    this.previousNodes = nodes;
    return nodes;
  }

  private mapConnections(rawConnections: Array<Object>): ConnectionInfo[] {
    if (!Array.isArray(rawConnections)) {
      return [];
    }
    return rawConnections.map((item: Object): ConnectionInfo => {
      const raw = item as Record<string, Object>;
      const metadata = raw.metadata as Record<string, Object> ?? {};
      const destinationPort = Number(metadata.destinationPort ?? metadata.dstPort ?? 0);
      const upload = Number(raw.upload ?? 0);
      const download = Number(raw.download ?? 0);
      return {
        id: String(raw.id ?? ''),
        host: String(metadata.host ?? ''),
        destinationIP: String(metadata.destinationIP ?? metadata.destinationIp ?? metadata.dstIP ?? ''),
        destinationPort: Number.isFinite(destinationPort) ? destinationPort : 0,
        network: String(metadata.network ?? ''),
        type: String(metadata.type ?? ''),
        chains: Array.isArray(raw.chains) ? (raw.chains as Array<string>).map((value: string) => String(value)) : [],
        rule: String(raw.rule ?? ''),
        upload: Number.isFinite(upload) ? upload : 0,
        download: Number.isFinite(download) ? download : 0,
        start: String(raw.start ?? '')
      };
    });
  }

  private updateTrafficTotals(upload: number, download: number, at: number): void {
    const elapsed = this.previousTrafficAt > 0 ? (at - this.previousTrafficAt) / 1000 : 0;
    if (this.previousTrafficAt > 0 && elapsed > 0) {
      this.snapshot.uploadRate = upload >= this.previousUploadTotal
        ? Math.max(0, (upload - this.previousUploadTotal) / elapsed) : 0;
      this.snapshot.downloadRate = download >= this.previousDownloadTotal
        ? Math.max(0, (download - this.previousDownloadTotal) / elapsed) : 0;
    } else {
      this.snapshot.uploadRate = 0;
      this.snapshot.downloadRate = 0;
    }
    this.previousUploadTotal = upload;
    this.previousDownloadTotal = download;
    this.previousTrafficAt = at;
    this.snapshot.uploadTotal = upload;
    this.snapshot.downloadTotal = download;
  }

  private async connectTelemetry(channel: 'traffic' | 'logs'): Promise<void> {
    if (this.disposed || this.snapshot.phase !== 'running' || this.state === undefined) {
      return;
    }
    const existing = channel === 'traffic' ? this.trafficSocket : this.logsSocket;
    if (existing !== undefined) {
      return;
    }
    const socket = webSocket.createWebSocket();
    let connectionClosed = false;
    const messageHandler = (_error: Error | undefined, data: string | ArrayBuffer): void => {
      if (this.disposed) {
        return;
      }
      const text = typeof data === 'string'
        ? data : util.TextDecoder.create('utf-8').decode(new Uint8Array(data));
      if (channel === 'traffic') {
        this.handleTrafficMessage(text);
      } else {
        this.handleLogMessage(text);
      }
    };
    const closeHandler = (_error: Error | undefined, _data: Object): void => {
      connectionClosed = true;
      if (channel === 'traffic') {
        if (this.trafficSocket === socket) {
          this.trafficSocket = undefined;
        }
        this.scheduleTelemetryReconnect('traffic');
      } else {
        if (this.logsSocket === socket) {
          this.logsSocket = undefined;
        }
        this.scheduleTelemetryReconnect('logs');
      }
    };
    const errorHandler = (_error: Error): void => {
      connectionClosed = true;
      if (channel === 'traffic') {
        if (this.trafficSocket === socket) {
          this.trafficSocket = undefined;
        }
        this.scheduleTelemetryReconnect('traffic');
      } else {
        if (this.logsSocket === socket) {
          this.logsSocket = undefined;
        }
        this.scheduleTelemetryReconnect('logs');
      }
    };
    const opened = new Promise<void>((resolve, reject) => {
      let completed = false;
      const timer = setTimeout((): void => {
        if (!completed) {
          completed = true;
          reject(new Error('websocket-timeout'));
        }
      }, 5000);
      socket.on('open', (error: Error | undefined, _data: Object): void => {
        if (!completed) {
          completed = true;
          clearTimeout(timer);
          if (error !== undefined) {
            reject(new Error('websocket-open'));
          } else {
            resolve();
          }
        }
      });
      socket.on('error', (error: Error): void => {
        if (!completed) {
          completed = true;
          clearTimeout(timer);
          reject(new Error('websocket-open'));
        }
      });
    });
    socket.on('message', messageHandler);
    socket.on('close', closeHandler);
    socket.on('error', errorHandler);
    try {
      const connected = await socket.connect(`ws://127.0.0.1:${CONTROLLER_PORT}/${channel}`, {
        header: { Authorization: `Bearer ${this.state.secret}` }
      });
      if (!connected) {
        throw new Error('websocket-connect');
      }
      await opened;
      if (connectionClosed) {
        throw new Error('websocket-closed');
      }
      if (this.disposed || this.snapshot.phase !== 'running') {
        this.closeSocket(socket, 'message', messageHandler);
        return;
      }
      if (channel === 'traffic') {
        this.trafficSocket = socket;
        this.trafficMessageHandler = messageHandler;
      } else {
        this.logsSocket = socket;
        this.logMessageHandler = messageHandler;
      }
    } catch (_) {
      this.closeSocket(socket, 'message', messageHandler);
      if (channel === 'traffic') {
        this.scheduleTelemetryReconnect('traffic');
      } else {
        this.scheduleTelemetryReconnect('logs');
      }
    }
  }

  private scheduleTelemetryReconnect(channel: 'traffic' | 'logs'): void {
    if (this.disposed || this.snapshot.phase !== 'running') {
      return;
    }
    if (channel === 'traffic') {
      if (this.trafficReconnectTimer !== -1) {
        return;
      }
      this.trafficReconnectTimer = setTimeout((): void => {
        this.trafficReconnectTimer = -1;
        void this.connectTelemetry('traffic');
      }, 2500);
    } else {
      if (this.logsReconnectTimer !== -1) {
        return;
      }
      this.logsReconnectTimer = setTimeout((): void => {
        this.logsReconnectTimer = -1;
        void this.connectTelemetry('logs');
      }, 2500);
    }
  }

  private handleTrafficMessage(text: string): void {
    try {
      const item = JSON.parse(text) as Record<string, number>;
      const upload = Number(item.upTotal ?? item.uploadTotal ?? item.upload ?? 0);
      const download = Number(item.downTotal ?? item.downloadTotal ?? item.download ?? 0);
      if (Number.isFinite(upload) && Number.isFinite(download)) {
        this.updateTrafficTotals(upload, download, Date.now());
        this.publish();
      }
    } catch (_) {
    }
  }

  private handleLogMessage(text: string): void {
    try {
      const item = JSON.parse(text) as Record<string, string>;
      const payload = this.sanitizeLog(item.payload ?? text);
      const log: LogInfo = { timestamp: Date.now(), type: String(item.type ?? 'info'), payload };
      this.snapshot.logs = [...this.snapshot.logs, log];
      if (this.snapshot.logs.length > MAX_LOGS) {
        this.snapshot.logs = this.snapshot.logs.slice(this.snapshot.logs.length - MAX_LOGS);
      }
      this.publish();
    } catch (_) {
      const log: LogInfo = { timestamp: Date.now(), type: 'info', payload: this.sanitizeLog(text) };
      this.snapshot.logs = [...this.snapshot.logs, log].slice(-MAX_LOGS);
      this.publish();
    }
  }

  private sanitizeLog(value: string): string {
    let text = value;
    if (this.state !== undefined && this.state.secret.length > 0) {
      text = text.split(this.state.secret).join('[REDACTED]');
    }
    return text.replace(/https?:\/\/[^\s"'<>]+/gi, '[URL]')
      .replace(/(authorization\s*[:=]\s*bearer\s+)\S+/gi, '$1[REDACTED]');
  }

  private closeSocket(socket: webSocket.WebSocket | undefined, event: 'message',
    handler: ((error: Error | undefined, data: string | ArrayBuffer) => void) | undefined): void {
    if (socket === undefined) {
      return;
    }
    try {
      socket.off(event, handler);
      socket.off('close');
      socket.off('error');
      socket.off('open');
      void socket.close().catch((): void => undefined);
    } catch (_) {
    }
  }

  private closeTelemetry(): void {
    this.closeSocket(this.trafficSocket, 'message', this.trafficMessageHandler);
    this.closeSocket(this.logsSocket, 'message', this.logMessageHandler);
    this.trafficSocket = undefined;
    this.logsSocket = undefined;
    this.trafficMessageHandler = undefined;
    this.logMessageHandler = undefined;
    if (this.trafficReconnectTimer !== -1) {
      clearTimeout(this.trafficReconnectTimer);
      this.trafficReconnectTimer = -1;
    }
    if (this.logsReconnectTimer !== -1) {
      clearTimeout(this.logsReconnectTimer);
      this.logsReconnectTimer = -1;
    }
  }

  private readRuntimeState(): RuntimeState | undefined {
    const value = safeJson(`${this.context.filesDir}/runtime-state.json`) as RuntimeState | undefined;
    if (value === undefined || (value.phase !== 'running' && value.phase !== 'starting' &&
      value.phase !== 'stopping' && value.phase !== 'stopped' && value.phase !== 'failed') ||
      typeof value.error !== 'string' || typeof value.profileId !== 'string' || typeof value.requestId !== 'string' ||
      !Number.isFinite(value.startedAt) || !Number.isFinite(value.heartbeat)) {
      return undefined;
    }
    return value;
  }

  private retainedSelections(id: string, inspection: Inspection): Record<string, string> {
    const retained: Record<string, string> = {};
    const previous = this.state!.selections[id] ?? {};
    for (const name of Object.keys(previous)) {
      const choice = previous[name];
      const group = inspection.groups.find((item: ProxyGroup) => item.name === name);
      if (group !== undefined && group.type.toLowerCase() === 'selector' &&
        (group.all.includes(choice) || inspection.dynamicGroups.includes(name))) {
        retained[name] = choice;
      } else if (name === 'GLOBAL' && group === undefined &&
        (choice === 'DIRECT' || choice === 'REJECT' ||
          inspection.nodes.some((node: NodeInfo) => node.name === choice) ||
          inspection.groups.some((item: ProxyGroup) => item.name === choice))) {
        retained[name] = choice;
      }
    }
    return retained;
  }

  private applyOfflineSelections(groups: ProxyGroup[]): ProxyGroup[] {
    if (this.state === undefined || this.state.activeProfileId.length === 0) {
      return groups;
    }
    const selections = this.state.selections[this.state.activeProfileId] ?? {};
    return groups.map((group: ProxyGroup): ProxyGroup => group.type.toLowerCase() === 'selector' &&
      selections[group.name] !== undefined && group.all.includes(selections[group.name])
      ? { name: group.name, type: group.type, all: group.all, now: selections[group.name] } : group);
  }

  private copyPersistedState(): PersistedState {
    return JSON.parse(JSON.stringify(this.state)) as PersistedState;
  }

  private cloneSnapshot(): AppSnapshot {
    return JSON.parse(JSON.stringify(this.snapshot)) as AppSnapshot;
  }

  private publish(): void {
    const current = this.cloneSnapshot();
    for (const listener of this.listeners) {
      try {
        listener(current);
      } catch (_) {
      }
    }
  }

  private writePrivateAtomic(path: string, text: string): void {
    const temp = `${path}.tmp-${Date.now()}-${Math.floor(Math.random() * 0x7fffffff)}`;
    try {
      const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
      fs.moveFileSync(temp, path, 0);
    } catch (_) {
      if (safeFileExists(temp)) {
        try {
          fs.unlinkSync(temp);
        } catch (_) {
        }
      }
      throw new Error('无法安全保存运行配置。');
    }
  }
}
