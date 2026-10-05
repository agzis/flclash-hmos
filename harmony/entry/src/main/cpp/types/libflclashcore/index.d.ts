export const inspect: (configText: string) => Promise<string>;
export const start: (optionsJson: string, tunFd: number) => Promise<void>;
export const stop: () => void;
export const refreshNetwork: () => void;
