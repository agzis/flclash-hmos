import { UIAbility, Configuration } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(stage: window.WindowStage): void {
    AppStorage.SetOrCreate<boolean>('systemDarkMode', this.context.resourceManager.getConfigurationSync().colorMode === 0);
    stage.loadContent('pages/Index', (error) => {
      if (error) {
        console.error(`Failed to load app content: ${error.code} ${error.message}`);
      }
    });
  }

  onConfigurationUpdate(configuration: Configuration): void {
    AppStorage.SetOrCreate<boolean>('systemDarkMode', configuration.colorMode === 0);
  }
}
