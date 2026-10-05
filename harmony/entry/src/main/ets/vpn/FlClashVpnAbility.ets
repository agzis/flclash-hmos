import { Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { connection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import * as nativeCore from 'libflclashcore.so';

interface RuntimeOptions {
  home: string;
  configPath: string;
  mode: 'rule' | 'global' | 'direct';
  port: number;
  secret: string;
  selections: Record<string, string>;
  requestId: string;
}

interface RuntimeStatus {
  phase: 'stopped' | 'starting' | 'running' | 'stopping' | 'failed';
  error: string;
  profileId: string;
  startedAt: number;
  heartbeat: number;
  requestId: string;
}

function fileExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (_) {
    return false;
  }
}

function safeError(value: Object | undefined, secret: string): string {
  let message = value === undefined ? '' : String(value);
  if (secret.length > 0) {
    message = message.split(secret).join('[REDACTED]');
  }
  message = message.replace(/https?:\/\/[^\s"'<>]+/gi, '[URL]')
    .replace(/(authorization\s*[:=]\s*bearer\s+)\S+/gi, '$1[REDACTED]');
  if (message.length > 240) {
    message = message.slice(0, 240);
  }
  return message.length > 0 ? message : 'VPN runtime startup failed';
}

export default class FlClashVpnAbility extends VpnExtensionAbility {
  private connection: vpnExtension.VpnConnection | undefined = undefined;
  private observer: connection.NetConnection | undefined = undefined;
  private operation: Promise<void> = Promise.resolve();
  private status: RuntimeStatus = {
    phase: 'stopped', error: '', profileId: '', startedAt: 0, heartbeat: 0, requestId: ''
  };
  private heartbeatTimer: number = -1;
  private destroyed: boolean = false;
  private observerRegistered: boolean = false;
  private statusPath: string = '';
  private physicalNetworks: Map<number, boolean> = new Map<number, boolean>();
  private netAvailableHandler: ((handle: connection.NetHandle) => void) | undefined = undefined;
  private netLostHandler: ((handle: connection.NetHandle) => void) | undefined = undefined;
  private capabilitiesHandler: ((info: connection.NetCapabilityInfo) => void) | undefined = undefined;
  private propertiesHandler: ((info: connection.NetConnectionPropertyInfo) => void) | undefined = undefined;
  private netUnavailableHandler: (() => void) | undefined = undefined;

  onRequest(want: Want, _startId: number): void {
    if (this.destroyed) {
      return;
    }
    const stopRequested = want.parameters?.action === 'stop';
    const stopRequestId = want.parameters?.requestId;
    this.operation = this.operation.then(async (): Promise<void> => {
      if (this.destroyed) {
        return;
      }
      if (stopRequested) {
        if (typeof stopRequestId !== 'string' || !/^[a-f0-9]{32}$/.test(stopRequestId)) {
          throw new Error('Invalid VPN stop request');
        }
        await this.stopRuntime(stopRequestId);
      } else if (this.connection === undefined) {
        await this.startRuntime();
      }
    }).catch((error: Error) => {
      if (!this.destroyed) {
        this.failRuntime(error);
      }
    });
  }

  onDestroy(): void {
    this.destroyed = true;
    nativeCore.stop();
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    this.status.phase = 'stopping';
    this.status.error = '';
    this.writeStatus();
    this.unregisterNetworkObserver();
    const connection = this.connection;
    this.connection = undefined;
    if (connection !== undefined) {
      void connection.destroy().then((): void => {
        this.status.phase = 'stopped';
        this.status.startedAt = 0;
        this.writeStatus();
      }).catch((_error: Error): void => {
        this.status.phase = 'failed';
        this.status.error = 'VPN 接口清理失败。';
        this.status.startedAt = 0;
        this.writeStatus();
        hilog.error(0x0000, 'FlClashVpn', 'VPN interface cleanup failed');
      });
    } else {
      this.status.phase = 'stopped';
      this.status.startedAt = 0;
      this.writeStatus();
    }
  }

  private async stopRuntime(requestId: string): Promise<void> {
    this.status.phase = 'stopping';
    this.status.error = '';
    this.status.requestId = requestId;
    this.writeStatus();
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    this.unregisterNetworkObserver();
    nativeCore.stop();
    const vpn = this.connection;
    if (vpn !== undefined) {
      await vpn.destroy();
      this.connection = undefined;
    }
    this.status.phase = 'stopped';
    this.status.startedAt = 0;
    this.writeStatus();
  }

  private async startRuntime(): Promise<void> {
    const options = this.readRuntimeOptions();
    this.status = {
      phase: 'starting', error: '', profileId: this.profileIdFor(options.configPath), startedAt: 0,
      heartbeat: Date.now(), requestId: options.requestId
    };
    this.writeStatus();
    this.startHeartbeat();
    const vpn = vpnExtension.createVpnConnection(this.context);
    this.connection = vpn;
    try {
      await vpn.protectProcessNet();
      if (this.destroyed) {
        return;
      }
      await this.registerNetworkObserver();
      if (this.destroyed) {
        this.unregisterNetworkObserver();
        return;
      }
      nativeCore.refreshNetwork();
      await this.copyGeodataAssets(options.home);
      if (this.destroyed) {
        return;
      }
      const fd = await vpn.create({
        addresses: [
          { address: { address: '172.19.0.1', family: 1 }, prefixLength: 30 },
          { address: { address: 'fdfe:dcba:9876::1', family: 2 }, prefixLength: 126 }
        ],
        routes: [
          {
            interface: 'vpn-tun',
            destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
            gateway: { address: '0.0.0.0', family: 1 }, hasGateway: false, isDefaultRoute: true
          },
          {
            interface: 'vpn-tun',
            destination: { address: { address: '::', family: 2 }, prefixLength: 0 },
            gateway: { address: '::', family: 2 }, hasGateway: false, isDefaultRoute: true
          }
        ],
        dnsAddresses: ['172.19.0.2', 'fdfe:dcba:9876::2'],
        mtu: 1400,
        isIPv4Accepted: true,
        isIPv6Accepted: true
      });
      if (this.destroyed) {
        nativeCore.stop();
        try {
          await vpn.destroy();
        } catch (_) {
        }
        if (this.connection === vpn) {
          this.connection = undefined;
        }
        return;
      }
      await nativeCore.start(JSON.stringify(options), fd);
      if (this.destroyed) {
        nativeCore.stop();
        try {
          await vpn.destroy();
        } catch (_) {
        }
        if (this.connection === vpn) {
          this.connection = undefined;
        }
        return;
      }
      this.status.phase = 'running';
      this.status.error = '';
      this.status.startedAt = Date.now();
      this.status.heartbeat = Date.now();
      this.writeStatus();
    } catch (error) {
      nativeCore.stop();
      const failedConnection = this.connection;
      this.connection = undefined;
      if (failedConnection !== undefined) {
        try {
          await failedConnection.destroy();
        } catch (_cleanupError) {
          hilog.error(0x0000, 'FlClashVpn', 'VPN interface cleanup failed after startup error');
        }
      }
      if (!this.destroyed) {
        throw error as Error;
      }
    }
  }

  private readRuntimeOptions(): RuntimeOptions {
    const path = `${this.context.filesDir}/runtime-options.json`;
    if (!fileExists(path)) {
      throw new Error('Runtime options are missing');
    }
    let options: RuntimeOptions;
    try {
      options = JSON.parse(fs.readTextSync(path)) as RuntimeOptions;
    } catch (_) {
      throw new Error('Runtime options could not be read');
    }
    if (options === null || typeof options !== 'object' || Array.isArray(options)) {
      throw new Error('Runtime options are invalid');
    }
    const profilePrefix = `${this.context.filesDir}/flclash/profiles/`;
    const configFile = typeof options.configPath === 'string' && options.configPath.startsWith(profilePrefix)
      ? options.configPath.slice(profilePrefix.length) : '';
    if (options.home !== `${this.context.filesDir}/mihomo` ||
      !/^[a-f0-9]{32}\.yaml$/.test(configFile) ||
      (options.mode !== 'rule' && options.mode !== 'global' && options.mode !== 'direct') ||
      options.port !== 9097 || typeof options.secret !== 'string' || !/^[a-f0-9]{64}$/.test(options.secret) ||
      typeof options.requestId !== 'string' || !/^[a-f0-9]{32}$/.test(options.requestId) ||
      options.selections === undefined || options.selections === null ||
      typeof options.selections !== 'object' || Array.isArray(options.selections)) {
      throw new Error('Runtime options are invalid');
    }
    return options;
  }

  private async registerNetworkObserver(): Promise<void> {
    const observer = connection.createNetConnection();
    this.observer = observer;
    this.netAvailableHandler = (handle: connection.NetHandle): void => {
      void this.refreshPhysicalNetwork(handle);
    };
    this.netLostHandler = (handle: connection.NetHandle): void => {
      if (!this.destroyed && this.physicalNetworks.has(handle.netId)) {
        this.physicalNetworks.delete(handle.netId);
        nativeCore.refreshNetwork();
      }
    };
    this.capabilitiesHandler = (info: connection.NetCapabilityInfo): void => {
      this.updatePhysicalNetwork(info.netHandle, info.netCap.bearerTypes);
    };
    this.propertiesHandler = (info: connection.NetConnectionPropertyInfo): void => {
      if (!this.destroyed && this.physicalNetworks.get(info.netHandle.netId) === true) {
        nativeCore.refreshNetwork();
      }
    };
    this.netUnavailableHandler = (): void => {
      if (!this.destroyed) {
        nativeCore.refreshNetwork();
      }
    };
    observer.on('netAvailable', this.netAvailableHandler);
    observer.on('netLost', this.netLostHandler);
    observer.on('netCapabilitiesChange', this.capabilitiesHandler);
    observer.on('netConnectionPropertiesChange', this.propertiesHandler);
    observer.on('netUnavailable', this.netUnavailableHandler);
    await new Promise<void>((resolve, reject) => {
      const registrationTimer = setTimeout((): void => {
        reject(new Error('Network observer registration timed out'));
      }, 5000);
      observer.register((error: Error | undefined): void => {
        clearTimeout(registrationTimer);
        if (error !== undefined) {
          reject(new Error('Network observer registration failed'));
        } else if (this.destroyed || this.observer !== observer) {
          observer.unregister((_unregisterError: Error | undefined): void => undefined);
          resolve();
        } else {
          this.observerRegistered = true;
          resolve();
        }
      });
    });
    if (this.destroyed) {
      this.unregisterNetworkObserver();
      return;
    }
    try {
      const defaultNetwork = await connection.getDefaultNet();
      if (defaultNetwork.netId > 0) {
        await this.refreshPhysicalNetwork(defaultNetwork);
      }
    } catch (_error) {
      if (!this.destroyed) {
        nativeCore.refreshNetwork();
      }
    }
  }

  private async refreshPhysicalNetwork(handle: connection.NetHandle): Promise<void> {
    if (this.destroyed) {
      return;
    }
    try {
      const capabilities = await connection.getNetCapabilities(handle);
      this.updatePhysicalNetwork(handle, capabilities.bearerTypes);
    } catch (_error) {
      if (!this.destroyed && this.physicalNetworks.get(handle.netId) === true) {
        nativeCore.refreshNetwork();
      }
    }
  }

  private updatePhysicalNetwork(handle: connection.NetHandle, bearers: Array<connection.NetBearType>): void {
    if (this.destroyed) {
      return;
    }
    const physical = bearers.includes(connection.NetBearType.BEARER_WIFI) ||
      bearers.includes(connection.NetBearType.BEARER_CELLULAR) ||
      bearers.includes(connection.NetBearType.BEARER_ETHERNET);
    if (physical) {
      this.physicalNetworks.set(handle.netId, true);
      nativeCore.refreshNetwork();
    } else if (this.physicalNetworks.has(handle.netId)) {
      this.physicalNetworks.delete(handle.netId);
      nativeCore.refreshNetwork();
    }
  }


  private unregisterNetworkObserver(): void {
    const observer = this.observer;
    if (observer === undefined) {
      return;
    }
    const registered = this.observerRegistered;
    this.observer = undefined;
    this.observerRegistered = false;
    this.physicalNetworks.clear();
    if (registered) {
      observer.unregister((error: Error | undefined): void => {
        if (error !== undefined) {
          hilog.error(0x0000, 'FlClashVpn', 'Network observer cleanup failed');
        }
      });
    }
    this.netAvailableHandler = undefined;
    this.netLostHandler = undefined;
    this.capabilitiesHandler = undefined;
    this.propertiesHandler = undefined;
    this.netUnavailableHandler = undefined;
  }
  private async copyGeodataAssets(home: string): Promise<void> {
    if (!fileExists(home)) {
      fs.mkdirSync(home, true);
    }
    const assets = ['GeoSite.dat', 'Country.mmdb', 'GeoIP.dat', 'cacert.pem'];
    for (const name of assets) {
      const target = `${home}/${name}`;
      if (fileExists(target) && fs.statSync(target).size > 0) {
        continue;
      }
      const contents = await this.context.resourceManager.getRawFileContent(name);
      const temporary = `${target}.tmp-${Date.now()}`;
      try {
        const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          const data = contents.byteOffset === 0 && contents.byteLength === contents.buffer.byteLength
            ? contents.buffer as ArrayBuffer
            : contents.buffer.slice(contents.byteOffset, contents.byteOffset + contents.byteLength) as ArrayBuffer;
          const written = fs.writeSync(file.fd, data);
          if (written !== contents.byteLength) {
            throw new Error('Incomplete runtime asset write');
          }
        } finally {
          fs.closeSync(file);
        }
        fs.moveFileSync(temporary, target, 0);
      } catch (error) {
        try {
          if (fileExists(temporary)) {
            fs.unlinkSync(temporary);
          }
        } catch (_) {
        }
        throw error as Error;
      }
    }
  }

  private startHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
    }
    this.heartbeatTimer = setInterval((): void => {
      if (!this.destroyed && this.status.phase !== 'stopped') {
        this.status.heartbeat = Date.now();
        this.writeStatus();
      }
    }, 3000);
  }

  private profileIdFor(configPath: string): string {
    const file = configPath.split('/').pop() ?? '';
    return file.endsWith('.yaml') ? file.slice(0, file.length - 5) : '';
  }

  private writeStatus(): void {
    this.status.heartbeat = Date.now();
    if (this.statusPath.length === 0) {
      this.statusPath = `${this.context.filesDir}/runtime-state.json`;
    }
    const path = this.statusPath;
    const temp = `${path}.tmp-${Date.now()}`;
    try {
      const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(this.status));
      } finally {
        fs.closeSync(file);
      }
      fs.moveFileSync(temp, path, 0);
    } catch (_error) {
      try {
        if (fileExists(temp)) {
          fs.unlinkSync(temp);
        }
      } catch (_) {
      }
      hilog.error(0x0000, 'FlClashVpn', 'Unable to atomically write VPN state');
    }
  }

  private failRuntime(error: Error): void {
    this.unregisterNetworkObserver();
    const optionsSecret = this.readSecretForSanitizing();
    this.status.phase = 'failed';
    this.status.error = safeError(error, optionsSecret);
    this.status.startedAt = 0;
    this.writeStatus();
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    const vpn = this.connection;
    this.connection = undefined;
    if (vpn !== undefined) {
      void vpn.destroy().catch((_cleanupError: Error) => {
        hilog.error(0x0000, 'FlClashVpn', 'VPN interface cleanup failed');
      });
    }
    hilog.error(0x0000, 'FlClashVpn', 'VPN runtime startup failed: %{public}s', this.status.error);
  }

  private readSecretForSanitizing(): string {
    try {
      const options = JSON.parse(fs.readTextSync(`${this.context.filesDir}/runtime-options.json`)) as RuntimeOptions;
      return typeof options.secret === 'string' ? options.secret : '';
    } catch (_) {
      return '';
    }
  }
}
