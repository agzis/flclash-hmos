export type ProxyMode = 'rule' | 'global' | 'direct';
export type ThemeMode = 'system' | 'light' | 'dark';
export type Phase = 'stopped' | 'starting' | 'running' | 'stopping' | 'failed';

export interface Profile {
  id: string;
  name: string;
  url: string;
  path: string;
  updatedAt: number;
  importedAt: number;
  usage: string;
}

export interface NodeInfo {
  name: string;
  type: string;
  delay: number;
}

export interface ProxyGroup {
  name: string;
  type: string;
  all: string[];
  now: string;
}

export interface ConnectionInfo {
  id: string;
  host: string;
  destinationIP: string;
  destinationPort: number;
  network: string;
  type: string;
  chains: string[];
  rule: string;
  upload: number;
  download: number;
  start: string;
}

export interface LogInfo {
  timestamp: number;
  type: string;
  payload: string;
}

export interface AppSnapshot {
  phase: Phase;
  message: string;
  profiles: Profile[];
  activeProfileId: string;
  mode: ProxyMode;
  theme: ThemeMode;
  groups: ProxyGroup[];
  nodes: NodeInfo[];
  uploadTotal: number;
  downloadTotal: number;
  uploadRate: number;
  downloadRate: number;
  connections: ConnectionInfo[];
  logs: LogInfo[];
  startedAt: number;
  testUrl: string;
}

export function createInitialSnapshot(): AppSnapshot {
  return {
    phase: 'stopped',
    message: 'VPN 已停止',
    profiles: [],
    activeProfileId: '',
    mode: 'rule',
    theme: 'system',
    groups: [],
    nodes: [],
    uploadTotal: 0,
    downloadTotal: 0,
    uploadRate: 0,
    downloadRate: 0,
    connections: [],
    logs: [],
    startedAt: 0,
    testUrl: 'https://www.gstatic.com/generate_204'
  };
}
