import type { IncomingMessage, Server, ServerResponse } from "node:http";

export interface QIPRouterOptions {
  contentRoot?: string;
  root?: string;
  recipesRoot?: string;
  componentsRoot?: string;
  elementsRoot?: string;
}

export interface ListenOptions {
  hostname?: string;
  port?: number;
}

export interface QIPResponse {
  status: number;
  headers: Headers;
  body: Uint8Array;
}

export interface QIPRouteEntry {
  method: "GET" | "HEAD";
  path: string;
  contentType: string;
}

export interface QIPRouter {
  readonly contentRoot: string;
  readonly recipesRoot: string;
  reload(): Promise<QIPRouter>;
  resolve(method: string, requestTarget: string): Promise<QIPResponse>;
  get(requestTarget: string): Promise<QIPResponse>;
  /** Returns response headers with an empty Uint8Array body. */
  head(requestTarget: string): Promise<QIPResponse>;
  list(): QIPRouteEntry[];
  warc(): Promise<Uint8Array>;
  fetch(request: Request): Promise<Response>;
  handler(request: IncomingMessage, response: ServerResponse): Promise<void>;
  listen(options?: ListenOptions): Promise<Server>;
}

export function createQIPRouter(options?: QIPRouterOptions): Promise<QIPRouter>;

export function main(argv?: string[]): Promise<void>;
