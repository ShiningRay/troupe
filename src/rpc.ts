import {Pid} from './core'

export interface RequestSpec {
    resolve: Function;
    reject: Function;
    timeout: number | NodeJS.Timer;
}

/**
 * RPC-style call, when call from outside actor, we treat it from default actor
 */
export function call(pid: Pid, method: string, args: any[]): PromiseLike<any> {
    return DefaultActor.__call(pid, method, args);
}