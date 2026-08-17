declare const contentContractBrand: unique symbol;
declare const contentComponentContractBrand: unique symbol;

export interface ContentContract {
  readonly [contentContractBrand]: true;
  readonly encoding: "bytes" | "utf8";
  readonly contentType?: string;
}

export interface ContentComponentContractOptions {
  label?: string;
  maxMemory?: number | string;
  input?: ContentContract;
  output?: ContentContract;
}

export interface ContentComponentContract {
  readonly [contentComponentContractBrand]: true;
  readonly label?: string;
  readonly maxMemory?: number;
  readonly input?: ContentContract;
  readonly output?: ContentContract;
}

export interface ComponentContractOptions {
  label?: string;
  maxMemory?: number | string;
}

export interface NewComponentOptions {
  label?: string;
  input?: ContentContract;
  output?: ContentContract;
}

export interface RecipeOptions {
  inputContentType?: string;
  capacitiesMustFit?: boolean;
}

export interface QIPRunComponent {
  label: string;
  module?: WebAssembly.Module;
  instance: WebAssembly.Instance;
  exports: WebAssembly.Exports;
  input: ContentContract;
  output: ContentContract;
  inputCapacity: number;
  outputCapacity: number;
}

export interface QIPRunStageSpec {
  component: QIPRunComponent;
  label?: string;
  uniforms?: Array<[key: string, value: string | number]>;
}

export type QIPRunRecipeStep = QIPRunStageSpec | QIPRunRecipe;

export interface QIPRunResult {
  readonly bytes: Uint8Array;
  readonly contentType: string;
  readonly outputEncoding: "bytes" | "utf8";
  readonly text: string;
}

export interface QIPRunStage {
  label: string;
  uniforms: Array<[key: string, value: string | number]>;
  component: QIPRunComponent;
  input: ContentContract;
  output: ContentContract;
  inputCapacity: number;
  outputCapacity: number;
}

export interface QIPRunPlan {
  stages: readonly QIPRunStage[];
  inputContentType: string;
  outputContentType: string;
  outputEncoding: "bytes" | "utf8";
}

export interface QIPRunRecipe extends QIPRunPlan {}

export function contentTypeUTF8(optionalMIMEType?: string): ContentContract;
export function contentTypeBytes(optionalMIMEType?: string): ContentContract;
export function newContentComponentContract(options?: ContentComponentContractOptions): ContentComponentContract;
export function wasmMustComplyWithComponentContract(wasm: Uint8Array | ArrayBuffer, options?: ComponentContractOptions | ContentComponentContract): void;
export function newComponent(instance: WebAssembly.Instance, options?: NewComponentOptions | ContentComponentContract): QIPRunComponent;
export function createRecipe(steps: QIPRunRecipeStep[], options?: RecipeOptions): QIPRunRecipe;
export function render(target: QIPRunComponent | QIPRunRecipe, input: Uint8Array | ArrayBuffer | string): QIPRunResult;

export function main(argv?: string[]): Promise<void>;
