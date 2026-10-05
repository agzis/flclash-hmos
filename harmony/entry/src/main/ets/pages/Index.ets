import { common } from '@kit.AbilityKit';
import picker from '@ohos.file.picker';
import { AppService } from '../services/AppService';
import { AppSnapshot, ConnectionInfo, LogInfo, Profile, ProxyGroup, ProxyMode, ThemeMode } from '../model/Models';
import bundleManager from '@ohos.bundle.bundleManager';

interface ModeChoice {
  value: ProxyMode;
  label: string;
}

interface ThemeChoice {
  value: ThemeMode;
  label: string;
}

const MODE_CHOICES: ModeChoice[] = [
  { value: 'rule', label: '规则' },
  { value: 'global', label: '全局' },
  { value: 'direct', label: '直连' }
];

const THEME_CHOICES: ThemeChoice[] = [
  { value: 'system', label: '跟随系统' },
  { value: 'light', label: '浅色' },
  { value: 'dark', label: '深色' }
];

@Entry
@Component
struct Index {
  @State private snapshot: AppSnapshot = {
    phase: 'stopped', message: '', profiles: [], activeProfileId: '', mode: 'rule', theme: 'system',
    groups: [], nodes: [], uploadTotal: 0, downloadTotal: 0, uploadRate: 0, downloadRate: 0,
    connections: [], logs: [], startedAt: 0, testUrl: ''
  };
  @State private section: string = 'home';
  @State private busy: boolean = false;
  @State private errorText: string = '';
  @State private notice: string = '';
  @State private profileName: string = '';
  @State private profileUrl: string = '';
  @State private renameId: string = '';
  @State private renameValue: string = '';
  @State private testUrlValue: string = '';
  @StorageProp('systemDarkMode') @Watch('onSystemThemeChange') private systemDarkMode: boolean = false;
  @State private dark: boolean = false;
  @State private appVersion: string = '读取中';
  @State private expandedConnection: string = '';

  private service?: AppService;
  private unsubscribe?: () => void;

  private onSystemThemeChange(): void {
    if (this.snapshot.theme === 'system') this.dark = this.systemDarkMode;
  }

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.service = new AppService(context);
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).then((info) => {
      this.appVersion = info.versionName || `${info.versionCode}`;
    }).catch(() => this.appVersion = '不可用');
    this.unsubscribe = this.service.subscribe((value: AppSnapshot) => {
      const previousTestUrl = this.snapshot.testUrl;
      this.snapshot = value;
      if (this.testUrlValue === previousTestUrl || this.testUrlValue.length === 0) {
        this.testUrlValue = value.testUrl;
      }
      this.updateTheme();
    });
    this.service.initialize().catch((error: Error) => this.showError(error));
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.service?.dispose();
  }

  private updateTheme(): void {
    // The app uses its own palette so explicit themes apply immediately; system follows resource configuration.
    if (this.snapshot.theme === 'dark') {
      this.dark = true;
    } else if (this.snapshot.theme === 'light') {
      this.dark = false;
    } else {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.dark = context.resourceManager.getConfigurationSync().colorMode === 0;
    }
  }

  private showError(error: Error): void {
    this.errorText = this.redactLog(error?.message || '操作失败');
    this.notice = '';
  }

  private async perform(action: () => Promise<void>, success?: string): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.errorText = '';
    this.notice = '正在处理…';
    try {
      await action();
      this.notice = success || '已完成';
    } catch (error) {
      this.showError(error as Error);
    } finally {
      this.busy = false;
    }
  }

  private async importUrl(): Promise<void> {
    const name = this.profileName.trim();
    const url = this.profileUrl.trim();
    if (!name || !url) { this.errorText = '请填写配置名称和订阅地址'; return; }
    await this.perform(async () => {
      await this.service!.importUrl(name, url);
      this.profileName = ''; this.profileUrl = '';
    }, '配置已导入');
  }

  private async importFile(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris = await documentPicker.select({ maxSelectNumber: 1 });
      if (uris.length === 0) return;
      const name = this.profileName.trim();
      if (!name) { this.errorText = '请先填写配置名称'; return; }
      await this.perform(async () => {
        await this.service!.importFile(name, uris[0]);
        this.profileName = '';
      }, '配置文件已导入');
    } catch (error) {
      this.showError(error as Error);
    }
  }

  private async renameProfile(): Promise<void> {
    const id = this.renameId;
    const name = this.renameValue.trim();
    if (!name) { this.errorText = '名称不能为空'; return; }
    await this.perform(async () => {
      await this.service!.renameProfile(id, name);
      this.renameId = '';
      this.renameValue = '';
    }, '名称已更新');
  }

  private async setTheme(theme: ThemeMode): Promise<void> {
    await this.perform(async () => {
      await this.service!.setTheme(theme);
      this.dark = theme === 'dark' || (theme === 'system' && this.systemDarkMode);
    }, '主题设置已保存');
  }

  private async saveTestUrl(): Promise<void> {
    const url = this.testUrlValue.trim();
    if (!url.startsWith('https://')) { this.errorText = '请输入 HTTPS 测试地址'; return; }
    await this.perform(() => this.service!.setTestUrl(url), '测试地址已保存');
  }

  private async confirmDelete(id: string, name: string): Promise<void> {
    AlertDialog.show({
      title: '删除配置', message: `确定删除“${name}”？`, alignment: DialogAlignment.Bottom,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: this.accent(), action: () => {
        this.perform(() => this.service!.deleteProfile(id), '配置已删除');
      } }
    });
  }

  private async runUpdate(id: string): Promise<void> {
    const profile = this.snapshot.profiles.find((item) => item.id === id);
    if (profile !== undefined && profile.url.length === 0) {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const documentPicker = new picker.DocumentViewPicker(context);
        const uris = await documentPicker.select({ maxSelectNumber: 1 });
        if (uris.length === 0) return;
        await this.perform(() => this.service!.updateProfile(id, uris[0]), '配置文件已替换');
      } catch (error) {
        this.showError(error as Error);
      }
    } else {
      await this.perform(() => this.service!.updateProfile(id), '配置已更新');
    }
  }

  private async selectProfile(id: string): Promise<void> {
    await this.perform(() => this.service!.selectProfile(id), '已切换配置');
  }

  private async toggleVpn(): Promise<void> {
    if (this.snapshot.phase === 'running') {
      await this.perform(() => this.service!.stop(), '代理已停止');
    } else {
      await this.perform(() => this.service!.start(), '代理已启动');
    }
  }

  private async setMode(mode: ProxyMode): Promise<void> {
    if (this.snapshot.mode === mode) return;
    await this.perform(() => this.service!.setMode(mode), '模式已更新');
  }

  private async selectNode(group: string, node: string): Promise<void> {
    await this.perform(() => this.service!.selectNode(group, node), '节点已选择');
  }

  private async testNode(node: string): Promise<void> {
    await this.perform(() => this.service!.testNode(node), '延迟测试完成');
  }

  private async closeConnection(id: string): Promise<void> {
    await this.perform(() => this.service!.closeConnection(id), '连接已关闭');
  }

  private async closeAllConnections(): Promise<void> {
    AlertDialog.show({
      title: '关闭全部连接', message: '将断开当前所有代理连接。', alignment: DialogAlignment.Bottom,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '关闭全部', fontColor: this.accent(), action: () => {
        this.perform(() => this.service!.closeAllConnections(), '连接已全部关闭');
      } }
    });
  }

  private phaseLabel(): string {
    switch (this.snapshot.phase) {
      case 'running': return '运行中';
      case 'starting': return '正在启动';
      case 'stopping': return '正在停止';
      case 'failed': return '启动失败';
      default: return '已停止';
    }
  }

  private activeProfileName(): string {
    const profile = this.snapshot.profiles.find((item) => item.id === this.snapshot.activeProfileId);
    return profile ? profile.name : '未选择配置';
  }


  private formatBytes(bytes: number): string {
    if (bytes < 1024) return `${Math.max(0, bytes).toFixed(0)} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
  }

  private formatRate(bytes: number): string {
    return `${this.formatBytes(bytes)}/s`;
  }

  private formatTime(timestamp: number): string {
    return timestamp > 0 ? new Date(timestamp).toLocaleString() : '—';
  }

  private pageBackground(): string { return this.dark ? '#101317' : '#F4F6F8'; }
  private card(): string { return this.dark ? '#1B2026' : '#FFFFFF'; }
  private text(): string { return this.dark ? '#F2F4F6' : '#19212B'; }
  private muted(): string { return this.dark ? '#9CA7B3' : '#687584'; }
  private accent(): string { return this.dark ? '#80B7FF' : '#1769C2'; }
  private accentText(): string { return this.dark ? '#101317' : '#FFFFFF'; }

  @Builder
  private header(title: string, subtitle: string) {
    Column({ space: 5 }) {
      Text(title).fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.text())
      Text(subtitle).fontSize(14).fontColor(this.muted())
    }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 18, bottom: 8 })
  }

  @Builder
  private cardTitle(title: string, trailing: string = '') {
    Row() {
      Text(title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.text()).layoutWeight(1)
      if (trailing.length > 0) { Text(trailing).fontSize(13).fontColor(this.muted()) }
    }.width('100%').margin({ bottom: 12 })
  }

  private redactLog(payload: string): string {
    return payload.replace(/https?:\/\/[^\s"'<>]+/gi, '[地址已隐藏]');
  }
  private nodeDelay(name: string): string {
    const node = this.snapshot.nodes.find((item) => item.name === name);
    return node && node.delay >= 0 ? `${node.delay} ms` : '未测试';
  }

  // Stable ForEach keys retain row callbacks; resolve mutable fields from the latest snapshot.
  private currentGroup(group: ProxyGroup): ProxyGroup {
    return this.snapshot.groups.find((item) => item.name === group.name) || group;
  }

  private currentProfile(profile: Profile): Profile {
    return this.snapshot.profiles.find((item) => item.id === profile.id) || profile;
  }

  private currentConnection(connection: ConnectionInfo): ConnectionInfo {
    return this.snapshot.connections.find((item) => item.id === connection.id) || connection;
  }

  private formatObserved(bytes: number): string {
    return bytes > 0 ? this.formatBytes(bytes) : '—';
  }

  private formatLiveRate(bytes: number): string {
    return this.snapshot.phase === 'running' ? this.formatRate(bytes) : '—';
  }


  @Builder
  private homePage() {
    Column({ space: 14 }) {
      this.header('FlClash', '代理状态与实时流量')
      Column({ space: 12 }) {
        Row() {
          Column({ space: 5 }) {
            Text(this.phaseLabel()).fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.text())
            Text(this.redactLog(this.snapshot.message || this.activeProfileName())).fontSize(14).fontColor(this.muted()).maxLines(2)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Row() {}.width(12).height(12).borderRadius(6)
            .backgroundColor(this.snapshot.phase === 'running' ? '#36B37E' :
              (this.snapshot.phase === 'failed' ? '#D94343' : this.muted()))
        }.width('100%')
        Button(this.snapshot.phase === 'running' ? '停止代理' : '启动代理')
          .width('100%').height(50).enabled(!this.busy && this.snapshot.phase !== 'starting' && this.snapshot.phase !== 'stopping')
          .backgroundColor(this.snapshot.phase === 'running' ? (this.dark ? '#39414B' : '#E8EDF2') : this.accent())
          .fontColor(this.snapshot.phase === 'running' ? this.text() : this.accentText()).onClick(() => this.toggleVpn())
        if (this.snapshot.phase === 'failed') {
          Button('停止并清理 VPN').width('100%').height(42).enabled(!this.busy)
            .backgroundColor(this.pageBackground()).fontColor(this.text())
            .onClick(() => this.perform(() => this.service!.stop(), 'VPN 已停止'))
        }
        Row() {
          Text('当前配置').fontSize(14).fontColor(this.muted()).layoutWeight(1)
          Text(this.activeProfileName()).fontSize(15).fontColor(this.text()).maxLines(1)
        }.width('100%')
      }.padding(18).width('100%').backgroundColor(this.card()).borderRadius(18)
      Column({ space: 12 }) {
        this.cardTitle('代理模式')
        Row({ space: 8 }) {
          ForEach(MODE_CHOICES, (item: ModeChoice) => {
              Button(item.label).layoutWeight(1).height(42)
                .backgroundColor(this.snapshot.mode === item.value ? this.accent() : this.pageBackground())
                .fontColor(this.snapshot.mode === item.value ? this.accentText() : this.text())
                .onClick(() => this.setMode(item.value));
            })
        }.width('100%')
      }.padding(18).width('100%').backgroundColor(this.card()).borderRadius(18)
      Column({ space: 14 }) {
        this.cardTitle('流量', '累计与当前速率')
        Row() {
          Column({ space: 6 }) {
            Text('下载').fontSize(13).fontColor(this.muted())
            Text(this.formatLiveRate(this.snapshot.downloadRate)).fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.text())
            Text(this.formatObserved(this.snapshot.downloadTotal)).fontSize(13).fontColor(this.muted())
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Column({ space: 6 }) {
            Text('上传').fontSize(13).fontColor(this.muted())
            Text(this.formatLiveRate(this.snapshot.uploadRate)).fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.text())
            Text(this.formatObserved(this.snapshot.uploadTotal)).fontSize(13).fontColor(this.muted())
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%')
      }.padding(18).width('100%').backgroundColor(this.card()).borderRadius(18)
      if (this.snapshot.phase === 'failed' && this.snapshot.message.length > 0) {
        Text(this.redactLog(this.snapshot.message)).fontSize(14).fontColor('#D94343').width('100%').padding(14)
      }
    }.width('100%')
  }

  @Builder
  private profilesPage() {
    Column({ space: 14 }) {
      this.header('配置', '管理订阅和本地配置文件')
      Column({ space: 10 }) {
        this.cardTitle('导入配置')
        TextInput({ placeholder: '配置名称', text: this.profileName }).onChange((value: string) => this.profileName = value)
          .fontColor(this.text()).placeholderColor(this.muted())
          .height(46).backgroundColor(this.pageBackground()).borderRadius(10).padding({ left: 12, right: 12 })
        TextInput({ placeholder: '订阅 HTTPS 地址', text: this.profileUrl }).onChange((value: string) => this.profileUrl = value)
          .type(InputType.URL)
          .fontColor(this.text()).placeholderColor(this.muted())
          .height(46).backgroundColor(this.pageBackground()).borderRadius(10).padding({ left: 12, right: 12 })
        Row({ space: 8 }) {
          Button('导入订阅').layoutWeight(1).height(44).backgroundColor(this.accent()).fontColor(this.accentText())
            .onClick(() => this.importUrl())
          Button('选择文件').layoutWeight(1).height(44).backgroundColor(this.pageBackground()).fontColor(this.text())
            .onClick(() => this.importFile())
        }.width('100%')
      }.padding(16).width('100%').backgroundColor(this.card()).borderRadius(18)
      Column({ space: 10 }) {
        Row() {
          Text('已保存配置').fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.text()).layoutWeight(1)
          Text(`${this.snapshot.profiles.length}`).fontSize(13).fontColor(this.muted())
        }.width('100%').margin({ bottom: 12 })
        if (this.snapshot.profiles.length === 0) {
          Text('尚无配置。导入订阅或从文件选择有效配置。').fontSize(14).fontColor(this.muted()).width('100%').padding(8)
        }
        ForEach(this.snapshot.profiles, (profile: Profile) => {
          Column({ space: 9 }) {
            Row() {
              Column({ space: 3 }) {
                Text(this.currentProfile(profile).name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.text()).maxLines(1)
                Text(profile.id === this.snapshot.activeProfileId ? '当前配置' : '未启用')
                  .fontSize(12).fontColor(profile.id === this.snapshot.activeProfileId ? this.accent() : this.muted())
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (profile.id !== this.snapshot.activeProfileId) {
                Button('使用').fontSize(13).height(34).backgroundColor(this.pageBackground()).fontColor(this.text())
                  .onClick(() => this.selectProfile(profile.id))
              }
            }.width('100%')
            Text(`更新于 ${this.formatTime(this.currentProfile(profile).updatedAt)}`).fontSize(12).fontColor(this.muted())
            if (this.currentProfile(profile).usage.length > 0) { Text(this.currentProfile(profile).usage).fontSize(12).fontColor(this.muted()).maxLines(2) }
            Row({ space: 6 }) {
              Button(profile.url.length > 0 ? '更新' : '替换文件').layoutWeight(1).height(36).fontSize(13).backgroundColor(this.pageBackground()).fontColor(this.text())
                .onClick(() => this.runUpdate(profile.id))
              Button('重命名').layoutWeight(1).height(36).fontSize(13).backgroundColor(this.pageBackground()).fontColor(this.text())
                .onClick(() => { this.renameId = profile.id; this.renameValue = this.currentProfile(profile).name; })
              Button('删除').layoutWeight(1).height(36).fontSize(13).backgroundColor(this.pageBackground()).fontColor('#C53939')
                .onClick(() => this.confirmDelete(profile.id, this.currentProfile(profile).name))
            }.width('100%')
            if (this.renameId === profile.id) {
              TextInput({ placeholder: '配置名称', text: this.renameValue }).onChange((value: string) => this.renameValue = value)
                .fontColor(this.text()).placeholderColor(this.muted())
                .height(42).backgroundColor(this.pageBackground()).borderRadius(10).padding({ left: 10, right: 10 })
              Row({ space: 8 }) {
                Button('保存名称').layoutWeight(1).onClick(() => this.renameProfile())
                Button('取消').layoutWeight(1).onClick(() => this.renameId = '')
              }.width('100%')
            }
          }.padding(14).width('100%').backgroundColor(this.card()).borderRadius(14)
        }, (profile: Profile) => profile.id)
      }.padding(16).width('100%').backgroundColor(this.card()).borderRadius(18)
    }.width('100%')
  }

  @Builder
  private proxiesPage() {
    Column({ space: 14 }) {
      this.header('代理', '选择代理组和节点')
      if (this.snapshot.phase !== 'running') {
        Text('代理未运行。启动后显示当前配置中的代理组和节点。').fontSize(14).fontColor(this.muted())
          .padding(16).width('100%').backgroundColor(this.card()).borderRadius(16)
      }
      if (this.snapshot.groups.length === 0 && this.snapshot.phase === 'running') {
        Text('当前配置未提供代理组。').fontSize(14).fontColor(this.muted())
          .padding(16).width('100%').backgroundColor(this.card()).borderRadius(16)
      }
      ForEach(this.snapshot.groups, (group: ProxyGroup) => {
        Column({ space: 8 }) {
          Row() {
            Column({ space: 3 }) {
              Text(group.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.text())
              Text(`${this.currentGroup(group).type} · 当前：${this.currentGroup(group).now || '未选择'}`).fontSize(12).fontColor(this.muted()).maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          ForEach(this.currentGroup(group).all, (node: string) => {
            Row() {
              Text(node).fontSize(14).fontColor(this.text()).layoutWeight(1).maxLines(1)
              Text(this.nodeDelay(node)).fontSize(12).fontColor(this.muted()).margin({ right: 8 })
              Button('测试').fontSize(12).height(32).backgroundColor(this.pageBackground()).fontColor(this.accent())
                .enabled(this.snapshot.phase === 'running' && !this.busy).onClick(() => this.testNode(node))
              if (this.currentGroup(group).now === node) {
                Text('已选').fontSize(12).fontColor(this.accent()).margin({ left: 8 })
              } else if (this.currentGroup(group).type.toLowerCase() === 'selector') {
                Button('选择').fontSize(12).height(32).backgroundColor(this.pageBackground()).fontColor(this.text())
                  .enabled(!this.busy).margin({ left: 6 }).onClick(() => this.selectNode(group.name, node))
              }
            }.width('100%').padding({ top: 6, bottom: 6 })
          }, (node: string) => node)
        }.padding(16).width('100%').backgroundColor(this.card()).borderRadius(16)
      }, (group: ProxyGroup) => group.name)
    }.width('100%')
  }

  @Builder
  private connectionsPage() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 5 }) {
          Text('连接').fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.text())
          Text(`${this.snapshot.connections.length} 个活动连接`).fontSize(14).fontColor(this.muted())
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('全部关闭').fontSize(13).height(36).backgroundColor(this.card()).fontColor('#C53939')
          .enabled(this.snapshot.connections.length > 0 && !this.busy).onClick(() => this.closeAllConnections())
      }.width('100%').padding({ top: 18, bottom: 8 })
      if (this.snapshot.connections.length === 0) {
        Text(this.snapshot.phase === 'running' ? '当前没有活动连接。' : '代理运行后将在此显示实际连接。')
          .fontSize(14).fontColor(this.muted()).padding(16).width('100%').backgroundColor(this.card()).borderRadius(16)
      }
      ForEach(this.snapshot.connections, (connection: ConnectionInfo) => {
        Column({ space: 8 }) {
          Row() {
            Column({ space: 3 }) {
              Text(connection.host || connection.destinationIP).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.text()).maxLines(1)
              Text(`${connection.type} · ${connection.network} · ${connection.destinationPort}`).fontSize(12).fontColor(this.muted())
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button(this.expandedConnection === connection.id ? '收起' : '详情').fontSize(12).height(32)
              .backgroundColor(this.pageBackground()).fontColor(this.accent())
              .onClick(() => this.expandedConnection = this.expandedConnection === connection.id ? '' : connection.id)
          }.width('100%')
          Row() {
            Text(`↓ ${this.formatBytes(this.currentConnection(connection).download)}`).fontSize(12).fontColor(this.muted()).layoutWeight(1)
            Text(`↑ ${this.formatBytes(this.currentConnection(connection).upload)}`).fontSize(12).fontColor(this.muted()).layoutWeight(1)
            Button('关闭').fontSize(12).height(32).backgroundColor(this.pageBackground()).fontColor('#C53939')
              .enabled(!this.busy).onClick(() => this.closeConnection(connection.id))
          }.width('100%')
          if (this.expandedConnection === connection.id) {
            Text(`目标：${connection.destinationIP}:${connection.destinationPort}\n规则：${connection.rule || '—'}\n链路：${connection.chains.join(' → ') || '—'}\n开始：${connection.start || '—'}`)
              .fontSize(12).fontColor(this.muted()).width('100%').padding(10).backgroundColor(this.pageBackground()).borderRadius(8)
          }
        }.padding(14).width('100%').backgroundColor(this.card()).borderRadius(16)
      }, (connection: ConnectionInfo) => connection.id)
    }.width('100%')
  }

  @Builder
  private logsPage() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 5 }) {
          Text('日志').fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.text())
          Text('来自运行代理的实时记录').fontSize(14).fontColor(this.muted())
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('清空').fontSize(13).height(36).backgroundColor(this.card()).fontColor(this.text())
          .enabled(this.snapshot.logs.length > 0).onClick(() => this.service?.clearLogs())
      }.width('100%').padding({ top: 18, bottom: 8 })
      if (this.snapshot.logs.length === 0) {
        Text('暂无日志。').fontSize(14).fontColor(this.muted()).padding(16).width('100%').backgroundColor(this.card()).borderRadius(16)
      }
      ForEach(this.snapshot.logs.slice().reverse(), (entry: LogInfo, index: number) => {
        Column({ space: 5 }) {
          Row() {
            Text(entry.type).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.accent()).layoutWeight(1)
            Text(this.formatTime(entry.timestamp)).fontSize(11).fontColor(this.muted())
          }.width('100%')
          Text(this.redactLog(entry.payload)).fontSize(12).fontColor(this.text()).width('100%').maxLines(5)
        }.padding(12).width('100%').backgroundColor(this.card()).borderRadius(12)
      }, (entry: LogInfo, index: number) => `${entry.timestamp}-${index}`)
    }.width('100%')
  }

  @Builder
  private settingsPage() {
    Column({ space: 14 }) {
      this.header('设置', '外观和测试配置')
      Column({ space: 12 }) {
        this.cardTitle('主题')
        ForEach(THEME_CHOICES, (item: ThemeChoice) => {
            Row() {
              Text(item.label).fontSize(15).fontColor(this.text()).layoutWeight(1)
              Radio({ value: item.value, group: 'theme' }).checked(this.snapshot.theme === item.value)
                .onChange((checked: boolean) => { if (checked) this.setTheme(item.value); })
            }.width('100%').height(42)
          })
      }.padding(16).width('100%').backgroundColor(this.card()).borderRadius(16)
      Column({ space: 10 }) {
        this.cardTitle('延迟测试地址')
        Text('仅支持 HTTPS；使用你信任且允许代理访问的地址。').fontSize(12).fontColor(this.muted())
        TextInput({ placeholder: '输入 HTTPS 地址', text: this.testUrlValue })
          .type(InputType.URL)
          .onChange((value: string) => this.testUrlValue = value).height(46)
          .fontColor(this.text()).placeholderColor(this.muted())
          .backgroundColor(this.pageBackground()).borderRadius(10).padding({ left: 12, right: 12 })
        Button('保存地址').width('100%').height(42).backgroundColor(this.accent()).fontColor(this.accentText())
          .onClick(() => this.saveTestUrl())
      }.padding(16).width('100%').backgroundColor(this.card()).borderRadius(16)
      Column({ space: 9 }) {
        this.cardTitle('关于')
        this.infoRow('应用', 'FlClash')
        this.infoRow('核心', 'Mihomo')
        this.infoRow('平台', 'HarmonyOS')
        this.infoRow('版本', this.appVersion)
      }.padding(16).width('100%').backgroundColor(this.card()).borderRadius(16)
    }.width('100%')
  }

  @Builder
  private infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(14).fontColor(this.muted()).layoutWeight(1)
      Text(value).fontSize(14).fontColor(this.text())
    }.width('100%')
  }

  @Builder
  private navItem(key: string, label: string) {
    Button(label).layoutWeight(1).height(52).fontSize(12)
      .backgroundColor(this.section === key ? (this.dark ? '#27384B' : '#E5F0FD') : this.card())
      .fontColor(this.section === key ? this.accent() : this.muted())
      .onClick(() => this.section = key)
  }

  build() {
    Column() {
          if (this.notice.length > 0 || this.errorText.length > 0) {
            Text(this.errorText.length > 0 ? this.errorText : this.notice)
              .fontSize(13).fontColor(this.errorText.length > 0 ? '#D94343' : this.accent())
              .width('100%').padding(12).backgroundColor(this.card()).borderRadius(10)
          }
      Scroll() {
        Column({ space: 14 }) {
          if (this.section === 'home') { this.homePage() }
          else if (this.section === 'profiles') { this.profilesPage() }
          else if (this.section === 'proxies') { this.proxiesPage() }
          else if (this.section === 'connections') { this.connectionsPage() }
          else if (this.section === 'logs') { this.logsPage() }
          else { this.settingsPage() }
        }.padding({ left: 18, right: 18, bottom: 18 }).width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      Row({ space: 2 }) {
        this.navItem('home', '概览')
        this.navItem('profiles', '配置')
        this.navItem('proxies', '代理')
        this.navItem('connections', '连接')
        this.navItem('logs', '日志')
        this.navItem('settings', '设置')
      }.width('100%').padding({ left: 8, right: 8, top: 6, bottom: 8 }).backgroundColor(this.card())
    }.width('100%').height('100%').backgroundColor(this.pageBackground())
  }
}
