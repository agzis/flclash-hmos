import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { url as urlUtils } from '@kit.ArkTS';
import { Profile, ProxyMode, ThemeMode } from '../model/Models';

export interface PersistedState {
  profiles: Profile[];
  activeProfileId: string;
  mode: ProxyMode;
  theme: ThemeMode;
  testUrl: string;
  secret: string;
  selections: Record<string, Record<string, string>>;
}

function hasFile(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (_) {
    return false;
  }
}

function toHex(bytes: Uint8Array): string {
  let value = '';
  for (let i = 0; i < bytes.length; i++) {
    value += bytes[i].toString(16).padStart(2, '0');
  }
  return value;
}

export async function secureRandomHex(bytes: number): Promise<string> {
  return toHex((await cryptoFramework.createRandom().generateRandom(bytes)).data);
}

export class PrivateStore {
  readonly root: string;
  readonly profileDir: string;
  readonly home: string;
  readonly statePath: string;
  private state: PersistedState;

  constructor(filesDir: string) {
    this.root = `${filesDir}/flclash`;
    this.profileDir = `${this.root}/profiles`;
    this.home = `${filesDir}/mihomo`;
    this.statePath = `${this.root}/app-state.json`;
    this.state = {
      profiles: [], activeProfileId: '', mode: 'rule', theme: 'system',
      testUrl: 'https://www.gstatic.com/generate_204', secret: '', selections: {}
    };
  }

  async load(): Promise<PersistedState> {
    if (!hasFile(this.profileDir)) {
      fs.mkdirSync(this.profileDir, true);
    }
    if (!hasFile(this.home)) {
      fs.mkdirSync(this.home, true);
    }
    if (hasFile(this.statePath)) {
      try {
        const stored = JSON.parse(fs.readTextSync(this.statePath)) as PersistedState;
        this.state = this.normalize(stored);
      } catch (_) {
        throw new Error('本地配置索引无法读取，原有配置未被修改。');
      }
    }
    if (this.state.secret.length === 0) {
      this.state.secret = await secureRandomHex(32);
      await this.save();
    }
    return this.copyState();
  }

  getState(): PersistedState {
    return this.copyState();
  }

  setState(next: PersistedState): void {
    this.state = this.normalize(next);
  }

  async save(): Promise<void> {
    if (!hasFile(this.root)) {
      fs.mkdirSync(this.root, true);
    }
    this.writeAtomic(this.statePath, JSON.stringify(this.state));
  }

  profilePath(id: string): string {
    return `${this.profileDir}/${id}.yaml`;
  }

  readProfile(profile: Profile): string {
    if (profile.path !== this.profilePath(profile.id)) {
      throw new Error('配置文件路径无效。');
    }
    return fs.readTextSync(profile.path);
  }

  writeProfileAtomic(id: string, yaml: string): void {
    this.writeAtomic(this.profilePath(id), yaml);
  }

  removeProfileFile(id: string): void {
    const path = this.profilePath(id);
    if (hasFile(path)) {
      fs.unlinkSync(path);
    }
  }

  async createProfileId(): Promise<string> {
    return secureRandomHex(16);
  }

  async updateProfileYaml(profile: Profile, yaml: string, commit: () => Promise<void>): Promise<void> {
    const path = this.profilePath(profile.id);
    const oldYaml = fs.readTextSync(path);
    this.writeAtomic(path, yaml);
    try {
      await commit();
    } catch (error) {
      this.writeAtomic(path, oldYaml);
      throw error as Error;
    }
  }

  private writeAtomic(path: string, content: string): void {
    const temporary = `${path}.tmp-${Date.now()}-${Math.floor(Math.random() * 0x7fffffff)}`;
    try {
      const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      fs.moveFileSync(temporary, path, 0);
    } catch (error) {
      if (hasFile(temporary)) {
        try {
          fs.unlinkSync(temporary);
        } catch (_) {
        }
      }
      throw error as Error;
    }
  }

  private normalize(value: PersistedState): PersistedState {
    if (value.mode !== 'rule' && value.mode !== 'global' && value.mode !== 'direct') {
      throw new Error('Invalid proxy mode');
    }
    if (value.theme !== 'system' && value.theme !== 'light' && value.theme !== 'dark') {
      throw new Error('Invalid theme mode');
    }
    const mode = value.mode;
    const theme = value.theme;
    if (!Array.isArray(value.profiles)) {
      throw new Error('Invalid profile index');
    }
    const profiles: Profile[] = [];
    const profileIds: Record<string, boolean> = {};
    for (const profile of value.profiles) {
      if (profile === undefined || profile === null || typeof profile.id !== 'string' ||
        !/^[a-f0-9]{32}$/.test(profile.id) || typeof profile.name !== 'string' ||
        profile.name.trim().length === 0 || typeof profile.url !== 'string' ||
        typeof profile.path !== 'string' || profile.path !== this.profilePath(profile.id) ||
        typeof profile.updatedAt !== 'number' || typeof profile.importedAt !== 'number' ||
        typeof profile.usage !== 'string') {
        throw new Error('Invalid profile record');
      }
      profiles.push(profile);
      if (profileIds[profile.id]) {
        throw new Error('Duplicate profile id');
      }
      profileIds[profile.id] = true;
      if (profile.url.length > 0) {
        try {
          const subscription = new urlUtils.URL(profile.url);
          if (subscription.protocol !== 'https:' && subscription.protocol !== 'http:') {
            throw new Error('Invalid subscription URL');
          }
        } catch (_) {
          throw new Error('Invalid subscription URL');
        }
      }
    }
    if (typeof value.activeProfileId !== 'string') {
      throw new Error('Invalid active profile id');
    }
    const activeProfileId = value.activeProfileId;
    if (activeProfileId.length > 0 && !profiles.some((profile: Profile) => profile.id === activeProfileId)) {
      throw new Error('Invalid active profile reference');
    }
    if (typeof value.secret !== 'string') {
      throw new Error('Invalid controller secret');
    }
    const secret = value.secret;
    if (secret.length > 0 && !/^[a-f0-9]{64}$/.test(secret)) {
      throw new Error('Invalid controller secret');
    }
    const testUrl = value.testUrl;
    if (typeof testUrl !== 'string' || testUrl.length === 0) {
      throw new Error('Invalid test URL');
    }
    try {
      const parsedUrl = new urlUtils.URL(testUrl);
      if (parsedUrl.protocol !== 'https:' || parsedUrl.username.length > 0 || parsedUrl.password.length > 0) {
        throw new Error('Invalid test URL');
      }
    } catch (_) {
      throw new Error('Invalid test URL');
    }
    if (value.selections === undefined || value.selections === null ||
      typeof value.selections !== 'object' || Array.isArray(value.selections)) {
      throw new Error('Invalid selector settings');
    }
    const selections = value.selections;
    return {
      profiles,
      activeProfileId,
      mode,
      theme,
      testUrl,
      secret,
      selections
    };
  }

  private copyState(): PersistedState {
    return JSON.parse(JSON.stringify(this.state)) as PersistedState;
  }
}
